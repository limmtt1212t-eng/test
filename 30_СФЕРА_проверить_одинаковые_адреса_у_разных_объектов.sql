/*
Запускать в DBeaver в подключении к «Сфере».

Зачем нужен запрос
------------------
Он находит случаи, когда один и тот же адрес для поиска ЕГРН используется
у нескольких разных object_id, и показывает, что находится за этими ID.

Адрес собирается ровно так же, как в предыдущей проверке ЕГРН:
населённый пункт + улица + дом + корпус + строение. Поэтому мы проверяем
именно те совпадения, которые были видны в результате Oracle.

Проверяется та же рабочая выборка, которую мы использовали для поиска ЕГРН:
- задача draft_contract;
- статус operational_archive;
- новый договор, пролонгация или незаполненный тип документа;
- нет отказа;
- недвижимость nedv_ul_and_ip;
- по каждому договору берётся последняя подходящая задача.

Важный момент
-------------
Одинаковый адрес ещё не означает, что это один объект недвижимости.
По одному адресу могут находиться несколько зданий, строений или помещений.
Кроме того, одна карточка физического объекта могла быть заведена заново
при пролонгации договора.

В результате одна строка — один object_id в последней задаче договора.
Первые колонки описывают всю группу с одинаковым адресом, остальные —
конкретную строку внутри этой группы.

После понятных диагностических колонок выводятся все физические столбцы
восьми основных таблиц. Их заголовки переведены на русский. В начале
каждого заголовка указан источник: «Задача», «Заявка», «Договор»,
«Связь задачи и объекта», «Характеристики», «Объект», «Адрес»
или «Страхователь».

Все основные денежные показатели собраны одним блоком сразу после номера
договора. Ниже по таблице они второй раз не повторяются.

У одного объекта может быть несколько строк в таблице условий страхования.
Чтобы из-за этого не размножать объекты, условия выводятся отдельно:
количество вариантов, минимальная и максимальная суммы, валюты, лимиты
и полный состав строк условий в одном JSON-массиве.

Название источника нужно потому, что в разных таблицах повторяются поля
«ID», «Статус», «Активность», «Дата создания» и «Дата изменения».

*/

with task_candidates as (
select
    contract.id as contract_id,
    request.id as request_id,
    contract.n_contract as contract_number,
    contract.rootcontract_id as root_contract_id,
    contract.prevcontract_id as previous_contract_id,
    contract.contractor_id as policyholder_id,
    task.id as task_id,
    task.d_create as task_created_at,
    row_number() over (
        partition by contract.id
        order by
            task.d_conclusion_ins_contract desc nulls last,
            task.d_create desc nulls last,
            task.d_change desc nulls last,
            task.id desc
    ) as task_number
from bps_request_ins_task task
join bps_request_ins request
    on request.id = task.request_ins_id
join bps_contract contract
    on contract.id = request.contract_id
where task.task_type = 'draft_contract'
  and task.status = 'operational_archive'
  and (
      task.ins_document_type = 'new_ins_contract'
      or task.ins_document_type = 'ins_contract_prolong'
      or task.ins_document_type is null
  )
  and task.ins_refuse is not true
  and task.d_delete is null
  and request.d_delete is null
  and contract.d_delete is null
),

selected_tasks as (
select
    contract_id,
    request_id,
    contract_number,
    root_contract_id,
    previous_contract_id,
    policyholder_id,
    task_id,
    task_created_at
from task_candidates
where task_number = 1
),

raw_object_rows as (
select
    selected.contract_id,
    selected.request_id,
    selected.contract_number,
    selected.root_contract_id,
    selected.previous_contract_id,
    selected.policyholder_id,
    policyholder.inn as policyholder_inn,
    policyholder.company_name_short as policyholder_name,
    selected.task_id,
    selected.task_created_at,
    task_object.id as task_object_link_id,
    task_object.object_group_id,
    task_object.characteristics_id,
    task_object.insured_sum as task_object_insured_sum,
    insurance_object.id as object_id,
    insurance_object.geo_address_id,
    insurance_object.obj_name as object_name,
    insurance_object.obj_type as object_type,
    insurance_object.elementary_obj_type,
    insurance_object.description as object_description,
    insurance_object.original_address,
    insurance_object.address_validation_code,
    insurance_object.is_address_validated_by_user,
    insurance_object.d_create as object_created_at,
    insurance_object.d_change as object_changed_at,
    characteristics.version_number as characteristics_version_number,
    characteristics.version_start_date as characteristics_version_start,
    characteristics.version_end_date as characteristics_version_end,
    characteristics.version_is_active as characteristics_version_is_active,
    characteristics.insurance_value,
    characteristics.is_pledged,
    characteristics.insurance_territory,
    characteristics.insured_components::text as insured_components,
    characteristics.activity_types::text as activity_types,
    characteristics.risk_natures::text as risk_natures,
    nullif(
        btrim(characteristics.characteristics ->> 'total_area_sq_m'),
        ''
    ) as area_raw,
    address.full_address,
    address.postal_code,
    address.region_id,
    address.area_type,
    address.area,
    address.settlement_type,
    address.settlement,
    address.street_type,
    address.street,
    address.house,
    address.building,
    address.block,
    address.flat,
    address.office,
    address.fias_code,
    address.longitude,
    address.latitude,
    address.address_dgis_id,
    case
        when nullif(btrim(address.full_address), '') is not null
            then 'base_geo_address.full_address'
        when nullif(btrim(insurance_object.original_address), '') is not null
            then 'base_insurance_object.original_address'
        else 'адрес отсутствует'
    end as address_source,
    coalesce(
        nullif(btrim(address.full_address), ''),
        nullif(btrim(insurance_object.original_address), '')
    ) as source_address,
    row_number() over (
        partition by selected.task_id, insurance_object.id
        order by
            task_object.d_change desc nulls last,
            task_object.d_create desc nulls last,
            characteristics.version_start_date desc nulls last,
            characteristics.version_number desc nulls last,
            task_object.id desc,
            characteristics.id desc
    ) as object_row_number
from selected_tasks selected
join bps_request_ins_task_insurance_object task_object
    on task_object.parent_id = selected.task_id
join base_insurance_object_characteristics characteristics
    on characteristics.id = task_object.characteristics_id
join base_insurance_object insurance_object
    on insurance_object.id = characteristics.insurance_object_id
left join base_geo_address address
    on address.id = insurance_object.geo_address_id
left join bps_contractor policyholder
    on policyholder.id = selected.policyholder_id
where insurance_object.elementary_obj_type = 'nedv_ul_and_ip'
  and insurance_object.d_delete is null
),

one_row_per_object as (
select
    raw_object_rows.*,
    nullif(
        regexp_replace(
            lower(
                replace(
                    replace(source_address, chr(160), ' '),
                    'ё',
                    'е'
                )
            ),
            '[^0-9a-zа-я]+',
            '',
            'g'
        ),
        ''
    ) as exact_address_match_key,
    case
        when replace(
            regexp_replace(area_raw, '[[:space:]]+', '', 'g'),
            ',',
            '.'
        ) ~ '^[0-9]+([.][0-9]+)?$'
        then replace(
            regexp_replace(area_raw, '[[:space:]]+', '', 'g'),
            ',',
            '.'
        )::numeric
        else null
    end as area_numeric,
    btrim(
        regexp_replace(
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        lower(
                            replace(
                                replace(source_address, chr(160), ' '),
                                'ё',
                                'е'
                            )
                        ),
                        '[;|]+',
                        ',',
                        'g'
                    ),
                    '[.]',
                    ' ',
                    'g'
                ),
                '[[:space:]]+',
                ' ',
                'g'
            ),
            '[[:space:]]*,[[:space:]]*',
            ', ',
            'g'
        )
    ) as address_lower
from raw_object_rows
where object_row_number = 1
  and source_address is not null
),

parsed_address as (
select
    one_row_per_object.*,
    coalesce(
        (regexp_match(
            address_lower,
            '(?:^|, )(?:г|город) ([^,]+)(?:,|$)'
        ))[1],
        nullif(btrim(settlement), ''),
        (regexp_match(
            address_lower,
            '(?:^|, )(?:пгт|поселок городского типа|рп|рабочий поселок|пос|поселок|с|село|д|деревня) ([^,]+)(?:,|$)'
        ))[1],
        (regexp_match(
            address_lower,
            '(?:^|, )([^,]+), (?:[^,]+ (?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея)|(?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея) [^,]+)(?:,|$)'
        ))[1]
    ) as parsed_locality,
    coalesce(
        nullif(btrim(street), ''),
        (regexp_match(
            address_lower,
            '(?:^|, )(?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея) ([^,]+)(?:,|$)'
        ))[1],
        (regexp_match(
            address_lower,
            '(?:^|, )([^,]+?) (?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея)(?:,|$)'
        ))[1]
    ) as parsed_street,
    coalesce(
        nullif(btrim(house), ''),
        (regexp_match(
            address_lower,
            '(?:^|, )(?:д|дом) *([0-9]+[а-яa-z]?(?:[/-][0-9а-яa-z]+)?)(?:,|$)'
        ))[1],
        (regexp_match(
            address_lower,
            '(?:^|, )([0-9]+[а-яa-z]?(?:[/-][0-9а-яa-z]+)?)$'
        ))[1]
    ) as parsed_house,
    coalesce(
        nullif(btrim(block), ''),
        (regexp_match(
            address_lower,
            '(?:^|, )(?:корп|корпус|к) *([0-9а-яa-z/-]+)(?:,|$)'
        ))[1]
    ) as parsed_korpus,
    coalesce(
        nullif(btrim(building), ''),
        (regexp_match(
            address_lower,
            '(?:^|, )(?:стр|строение) *([0-9а-яa-z/-]+)(?:,|$)'
        ))[1]
    ) as parsed_stroenie
from one_row_per_object
),

normalized_parts as (
select
    parsed_address.*,
    nullif(
        regexp_replace(
            btrim(replace(lower(parsed_locality), 'ё', 'е')),
            '[[:space:]]+',
            ' ',
            'g'
        ),
        ''
    ) as match_locality,
    nullif(
        regexp_replace(
            btrim(replace(lower(parsed_street), 'ё', 'е')),
            '[[:space:]]+',
            ' ',
            'g'
        ),
        ''
    ) as match_street,
    nullif(
        replace(btrim(replace(lower(parsed_house), 'ё', 'е')), ' ', ''),
        ''
    ) as match_house,
    nullif(
        replace(btrim(replace(lower(parsed_korpus), 'ё', 'е')), ' ', ''),
        ''
    ) as match_korpus,
    nullif(
        replace(btrim(replace(lower(parsed_stroenie), 'ё', 'е')), ' ', ''),
        ''
    ) as match_stroenie
from parsed_address
),

objects_prepared_for_egrn as (
select
    normalized_parts.*,
    concat_ws(
        '|',
        match_locality,
        match_street,
        match_house,
        coalesce(match_korpus, ''),
        coalesce(match_stroenie, '')
    ) as address_match_key,
    match_locality
        || ', ' || match_street
        || ', ' || match_house
        || case
            when match_korpus is not null
                then ', корпус ' || match_korpus
            else ''
        end
        || case
            when match_stroenie is not null
                then ', строение ' || match_stroenie
            else ''
        end as address_for_egrn_search
from normalized_parts
where match_locality is not null
  and match_street is not null
  and match_house is not null
),

exact_address_stats as (
/*
Здесь адрес не сокращается до дома: квартира, офис или
помещение остаются в строке. Это позволяет отличить разные
помещения внутри одного здания.
*/
select
    exact_address_match_key,
    count(distinct object_id) as exact_address_object_count
from objects_prepared_for_egrn
where exact_address_match_key is not null
group by exact_address_match_key
),

address_stats as (
select
    address_match_key,
    min(address_for_egrn_search) as address_example,
    count(*) as row_count,
    count(distinct object_id) as object_count,
    count(distinct task_id) as task_count,
    count(distinct characteristics_id) as characteristics_count,
    count(distinct contract_id) as contract_count,
    count(distinct coalesce(root_contract_id, contract_id))
        as contract_chain_count,
    count(distinct policyholder_id) as policyholder_count,
    count(distinct geo_address_id) as geo_address_id_count,
    count(distinct exact_address_match_key) as exact_address_count,
    count(region_id) as rows_with_region_id,
    count(distinct region_id) as region_id_count,
    count(nullif(btrim(settlement_type), '')) as rows_with_settlement_type,
    count(distinct settlement_type) as settlement_type_count,
    count(nullif(btrim(street_type), '')) as rows_with_street_type,
    count(distinct street_type) as street_type_count,
    count(distinct object_group_id) as object_group_count,
    count(distinct address_dgis_id) as dgis_id_count,
    count(distinct concat(coalesce(flat, ''), '|', coalesce(office, '')))
        filter (where flat is not null or office is not null) as unit_count,
    count(*) filter (where flat is not null or office is not null)
        as rows_with_unit,
    count(distinct concat(longitude::text, '|', latitude::text)) filter (
        where longitude is not null and latitude is not null
    ) as coordinate_count,
    count(area_numeric) as rows_with_area,
    count(distinct area_numeric) as different_area_count,
    min(area_numeric) as minimum_area,
    max(area_numeric) as maximum_area,
    count(distinct nullif(btrim(object_description), ''))
        as different_description_count,
    count(nullif(btrim(fias_code), '')) as rows_with_fias,
    count(distinct nullif(btrim(fias_code), '')) as fias_count
from objects_prepared_for_egrn
where address_match_key is not null
group by address_match_key
having count(distinct object_id) > 1
),

ranked_addresses as (
select
    address_stats.*,
    row_number() over (
        order by object_count desc, contract_count desc, address_example
    ) as address_group_number
from address_stats
)

select
    duplicate.address_group_number
        as "№ группы адреса",
    duplicate.address_example
        as "Одинаковый адрес для поиска",
    duplicate.row_count
        as "Строк в группе",
    duplicate.object_count
        as "Разных ID объекта по адресу",
    duplicate.task_count
        as "Разных задач по адресу",
    duplicate.characteristics_count
        as "Разных ID характеристик",
    duplicate.contract_count
        as "Разных договоров по адресу",
    duplicate.contract_chain_count
        as "Разных цепочек договоров",
    duplicate.policyholder_count
        as "Разных страхователей по адресу",
    duplicate.geo_address_id_count
        as "Разных ID записи адреса",
    duplicate.exact_address_count
        as "Точных адресов с квартирой/офисом",
    duplicate.rows_with_region_id
        as "Строк с ID региона",
    duplicate.region_id_count
        as "Разных ID региона",
    duplicate.rows_with_settlement_type
        as "Строк с типом населённого пункта",
    duplicate.settlement_type_count
        as "Разных типов населённого пункта",
    duplicate.rows_with_street_type
        as "Строк с типом улицы",
    duplicate.street_type_count
        as "Разных типов улицы",
    duplicate.object_group_count
        as "Разных групп объектов",
    duplicate.dgis_id_count
        as "Разных ID 2ГИС",
    duplicate.unit_count
        as "Разных квартир/офисов",
    duplicate.rows_with_unit
        as "Строк с квартирой/офисом",
    duplicate.coordinate_count
        as "Разных координат",
    duplicate.rows_with_area
        as "Строк с площадью",
    duplicate.different_area_count
        as "Разных площадей",
    duplicate.minimum_area
        as "Минимальная площадь",
    duplicate.maximum_area
        as "Максимальная площадь",
    duplicate.different_description_count
        as "Разных описаний объекта",
    duplicate.rows_with_fias
        as "Строк с ФИАС из Сферы",
    duplicate.fias_count
        as "Разных заполненных ФИАС",
    case
        when duplicate.policyholder_count > 1
            then 'Адрес встречается у разных страхователей'
        when duplicate.contract_count > 1
         and duplicate.contract_chain_count = 1
            then 'Один страхователь и одна цепочка договоров: возможна повторная карточка при пролонгации'
        when duplicate.contract_count > 1
            then 'Один страхователь, но разные цепочки договоров'
        else 'Один договор содержит несколько объектов по одному адресу'
    end as "Что видно по группе",
    case
        when duplicate.rows_with_area = 0
            then 'Площади нет: различить объекты по площади нельзя'
        when duplicate.different_area_count > 1
            then 'Площади разные: скорее всего, это разные объекты'
        when duplicate.rows_with_area < duplicate.row_count
            then 'У заполненных строк площадь совпадает, но часть площадей пустая'
        else 'Площадь совпадает: это может быть один физический объект, но это ещё не доказано'
    end as "Что видно по площади",
    case
        when duplicate.region_id_count > 1
            then 'Опасно: регион не входил в ключ поиска, а регионы разные'
        when duplicate.rows_with_region_id < duplicate.row_count
            then 'Опасно: регион не входил в ключ поиска и частично или полностью пуст'
        when duplicate.settlement_type_count > 1
          or duplicate.street_type_count > 1
            then 'Опасно: тип населённого пункта или улицы не входил в ключ'
        when duplicate.rows_with_settlement_type < duplicate.row_count
          or duplicate.rows_with_street_type < duplicate.row_count
            then 'Проверить: тип населённого пункта или улицы не заполнен'
        when duplicate.rows_with_unit > 0
            then 'Опасно: квартира/офис не входили в ключ поиска'
        when duplicate.coordinate_count > 1
            then 'Проверить: у одинакового адреса разные координаты'
        when duplicate.policyholder_count > 1
            then 'Нельзя склеивать только по адресу: страхователи разные'
        when duplicate.different_area_count > 1
            then 'Нельзя склеивать только по адресу: площади разные'
        else 'Нужна ручная проверка типа, описания, площади и договорной цепочки'
    end as "Главный подводный камень",

    object_rows.contract_id as "ID договора",
    object_rows.request_id as "ID заявки",
    object_rows.contract_number as "Номер договора",

    /* Денежные показатели договора и объекта собраны рядом. */
    source_task."total_ins_contract_amount"
        as "Общая страховая сумма по договору",
    source_task."curr_ins_contract_amount"
        as "Валюта общей суммы договора",
    source_task."total_ins_contract_premium"
        as "Общая страховая премия договора",
    source_task."total_ins_contract_rate"
        as "Общий страховой тариф договора",
    object_rows.insurance_value
        as "Страховая стоимость объекта",
    source_characteristics."insurance_value_currency"
        as "Валюта стоимости объекта",
    source_characteristics."insurance_value_basis"
        as "Основание стоимости объекта",
    object_rows.is_pledged
        as "Признак залога",
    source_characteristics."pledged_value"
        as "Залоговая стоимость объекта",
    object_rows.task_object_insured_sum
        as "Сумма объекта из связи с задачей",
    source_task_object."insured_sum_currency"
        as "Валюта суммы из связи с задачей",
    source_task_object."per_occurance_limit"
        as "Лимит по случаю из связи с задачей",
    source_conditions.condition_row_count
        as "Кол-во условий объекта",
    source_conditions.rows_with_insured_sum
        as "Условий с суммой",
    source_conditions.distinct_insured_sum_count
        as "Разных сумм в условиях объекта",
    source_conditions.minimum_insured_sum
        as "Мин. сумма объекта из условий",
    source_conditions.maximum_insured_sum
        as "Макс. сумма объекта из условий",
    source_conditions.insured_sum_currencies
        as "Валюты сумм из условий",
    source_conditions.minimum_per_occurrence_limit
        as "Мин. лимит по случаю из условий",
    source_conditions.maximum_per_occurrence_limit
        as "Макс. лимит по случаю из условий",
    case
        when object_rows.task_object_insured_sum is not null
         and source_conditions.rows_with_insured_sum > 0
            then 'Сумма есть и в связи с задачей, и в условиях'
        when object_rows.task_object_insured_sum is not null
            then 'Сумма есть только в связи с задачей'
        when source_conditions.rows_with_insured_sum > 0
            then 'Сумма есть только в условиях страхования'
        else 'Сумма объекта не найдена в двух источниках'
    end as "Источник страховой суммы объекта",
    source_conditions.all_condition_rows
        as "Все варианты условий объекта JSON",

    object_rows.root_contract_id as "ID главного договора",
    object_rows.previous_contract_id as "ID предыдущего договора",
    object_rows.policyholder_id as "ID страхователя",
    object_rows.policyholder_inn as "ИНН страхователя",
    object_rows.policyholder_name as "Страхователь",
    object_rows.task_id as "ID задачи",
    object_rows.task_created_at as "Дата задачи",
    object_rows.task_object_link_id as "ID связи задача-объект",
    object_rows.object_group_id as "ID группы объектов",
    object_rows.characteristics_id as "ID характеристик",
    object_rows.object_id as "ID объекта",
    object_rows.geo_address_id as "ID записи адреса",
    object_rows.fias_code as "ФИАС объекта из Сферы",
    case
        when nullif(btrim(object_rows.fias_code), '') is null
            then 'нет'
        else 'да'
    end as "ФИАС заполнен",
    object_rows.address_source as "Откуда взят адрес",
    object_rows.address_for_egrn_search as "Адрес Сферы для поиска",
    object_rows.source_address as "Адрес-источник до разбора",
    exact.exact_address_object_count
        as "ID объектов по этому точному адресу",
    object_rows.original_address as "Исходный адрес",
    object_rows.address_validation_code as "Код проверки адреса",
    object_rows.is_address_validated_by_user as "Адрес подтверждён пользователем",
    object_rows.full_address as "Нормализованный адрес",
    object_rows.postal_code as "Индекс",
    object_rows.region_id as "ID региона",
    object_rows.area_type as "Тип района",
    object_rows.area as "Район",
    object_rows.settlement_type as "Тип населённого пункта",
    object_rows.settlement as "Населённый пункт",
    object_rows.street_type as "Тип улицы",
    object_rows.street as "Улица",
    object_rows.house as "Дом",
    object_rows.building as "Строение",
    object_rows.block as "Корпус",
    object_rows.flat as "Квартира/помещение",
    object_rows.office as "Офис",
    object_rows.longitude as "Долгота",
    object_rows.latitude as "Широта",
    object_rows.address_dgis_id as "ID адреса 2ГИС",
    object_rows.object_name as "Название объекта",
    object_rows.object_type as "Тип объекта",
    object_rows.elementary_obj_type as "Системный тип объекта",
    object_rows.object_description as "Описание объекта",
    object_rows.area_raw as "Площадь как записана",
    object_rows.area_numeric as "Площадь числом",
    object_rows.insurance_territory as "Территория страхования",
    object_rows.insured_components as "Что застраховано",
    object_rows.activity_types as "Виды деятельности",
    object_rows.risk_natures as "Характеры риска",
    object_rows.characteristics_version_number as "Номер версии характеристик",
    object_rows.characteristics_version_start as "Начало версии характеристик",
    object_rows.characteristics_version_end as "Окончание версии характеристик",
    object_rows.characteristics_version_is_active as "Активная версия",
    object_rows.object_created_at as "Дата создания объекта",
    object_rows.object_changed_at as "Дата изменения объекта",

    /* Ниже добавлены все физические столбцы исходных таблиц.
       Заголовок каждого столбца показывает источник и смысл поля. */
    source_insurance_object."id" as "Объект: ID объекта страхования",
    source_insurance_object."obj_type" as "Объект: Тип объекта",
    source_insurance_object."elementary_obj_type" as "Объект: Подтип или элементарный…",
    source_insurance_object."obj_name" as "Объект: Название объекта",
    source_insurance_object."description" as "Объект: Описание объекта",
    source_insurance_object."original_address" as "Объект: Адрес",
    source_insurance_object."geo_address_id" as "Объект: ID адреса",
    source_insurance_object."address_validation_code" as "Объект: Код валидации адреса",
    source_insurance_object."is_address_validated_by_user" as "Объект: Валидный адрес",
    source_insurance_object."created_by" as "Объект: ID создателя",
    source_insurance_object."changed_by" as "Объект: ID изменившего",
    source_insurance_object."d_create" as "Объект: Дата создания",
    source_insurance_object."d_change" as "Объект: Дата изменения",
    source_insurance_object."d_delete" as "Объект: Дата удаления",
    source_insurance_object."active" as "Объект: Активность",
    source_insurance_object."user_change_id" as "Объект: ID изменения",
    source_insurance_object."author_id" as "Объект: ID автора",
    source_characteristics."id" as "Характеристики: ID набора характе…",
    source_characteristics."insurance_object_id" as "Характеристики: ID объекта страхо…",
    source_characteristics."characteristics" as "Характеристики: Характеристики…",
    source_characteristics."version_number" as "Характеристики: Номер версии",
    source_characteristics."version_start_date" as "Характеристики: Дата начала рабо…",
    source_characteristics."version_end_date" as "Характеристики: Дата окончания р…",
    source_characteristics."version_is_active" as "Характеристики: Активная версия",
    source_characteristics."created_by" as "Характеристики: ID создателя",
    source_characteristics."changed_by" as "Характеристики: ID изменившего",
    source_characteristics."d_create" as "Характеристики: Дата создания",
    source_characteristics."d_change" as "Характеристики: Дата изменения",
    source_characteristics."user_change_id" as "Характеристики: ID изменения",
    source_characteristics."author_id" as "Характеристики: ID автора",
    source_characteristics."risk_natures" as "Характеристики: Характеры риска",
    source_characteristics."activity_types" as "Характеристики: Типы деятельности",
    source_characteristics."ownership_type" as "Характеристики: Право владения",
    source_characteristics."is_pledged" as "Характеристики: Объект является…",
    source_characteristics."insured_components" as "Характеристики: Элементы, подлеж…",
    source_characteristics."insurance_object_loss_history" as "Характеристики: Информация об уб…",
    source_characteristics."has_losses" as "Характеристики: Наличие убытков",
    source_characteristics."insurance_territory" as "Характеристики: Территория стра…",
    source_characteristics."region" as "Характеристики: Регион",
    source_characteristics."pledgee_inn" as "Характеристики: ИНН Залогодержа…",
    source_characteristics."is_leased" as "Характеристики: Объект находитс…",
    source_characteristics."lessor_inn" as "Характеристики: ИНН Лизингодателя",
    source_address."full_address" as "Адрес: Полный адрес",
    source_address."postal_code" as "Адрес: Индекс",
    source_address."region_id" as "Адрес: ID региона",
    source_address."city_id" as "Адрес: ID города",
    source_address."area_type" as "Адрес: Тип района",
    source_address."area" as "Адрес: Район",
    source_address."settlement_type" as "Адрес: Тип населённого пункта",
    source_address."settlement" as "Адрес: Населённый пункт",
    source_address."street_type" as "Адрес: Тип улицы",
    source_address."street" as "Адрес: Улица",
    source_address."house" as "Адрес: Дом",
    source_address."building" as "Адрес: Строение",
    source_address."block" as "Адрес: Номер корпуса или блока",
    source_address."flat" as "Адрес: Комната",
    source_address."office" as "Адрес: Кв",
    source_address."fias_code" as "Адрес: Код адресного объекта в ФИ…",
    source_address."longitude" as "Адрес: Географическая долгота",
    source_address."latitude" as "Адрес: Географическая широта",
    source_address."point" as "Адрес: Географическая точка с ко…",
    source_address."id" as "Адрес: ID адреса",
    source_address."d_create" as "Адрес: Дата создания",
    source_address."d_change" as "Адрес: Дата изменения",
    source_address."user_change_id" as "Адрес: ID изменения",
    source_address."author_id" as "Адрес: ID автора",
    source_address."timezone" as "Адрес: Временная зона",
    source_address."address_dgis_id" as "Адрес: ID адреса в 2ГИС",
    source_policyholder."id" as "Страхователь: ID контрагента",
    source_policyholder."d_create" as "Страхователь: Дата создания запи…",
    source_policyholder."active" as "Страхователь: Активность",
    source_policyholder."status" as "Страхователь: Текущий этап бизне…",
    source_policyholder."d_change" as "Страхователь: Дата последнего из…",
    source_policyholder."data" as "Страхователь: Данные о контраген…",
    source_policyholder."contractor_type" as "Страхователь: Тип контрагента",
    source_policyholder."last_name" as "Страхователь: Фамилия",
    source_policyholder."first_name" as "Страхователь: Имя",
    source_policyholder."gender" as "Страхователь: Пол",
    source_policyholder."birth_day" as "Страхователь: Дата рождения",
    source_policyholder."company_register_day" as "Страхователь: Дата регистрации",
    source_policyholder."company_form" as "Страхователь: Организационно-пр…",
    source_policyholder."company_name_full" as "Страхователь: Полное наименование",
    source_policyholder."company_name_short" as "Страхователь: Краткое наименова…",
    source_policyholder."ogrn" as "Страхователь: ОГРН",
    source_policyholder."ogrnip" as "Страхователь: ОГРНИП",
    source_policyholder."kpp" as "Страхователь: КПП",
    source_policyholder."inn" as "Страхователь: ИНН",
    source_policyholder."responsible_id" as "Страхователь: id ответственного",
    source_policyholder."author_id" as "Страхователь: id автора",
    source_policyholder."resident" as "Страхователь: Резидент",
    source_policyholder."middle_name" as "Страхователь: Отчество",
    source_policyholder."sbs_id" as "Страхователь: id СБС",
    source_policyholder."data_hash" as "Страхователь: Контрольная сумма…",
    source_policyholder."search_name" as "Страхователь: Название для поиска",
    source_policyholder."snils" as "Страхователь: СНИЛС",
    source_policyholder."not_sync_fields" as "Страхователь: Параметры, которые…",
    source_policyholder."title" as "Страхователь: Отображаемое назв…",
    source_policyholder."author_remote_addr" as "Страхователь: IP адрес автора, соз…",
    source_policyholder."first_name_genitive" as "Страхователь: Имя (в родительном…",
    source_policyholder."last_name_genitive" as "Страхователь: Фамилия (в родител…",
    source_policyholder."middle_name_genitive" as "Страхователь: Отчество (в родите…",
    source_policyholder."wiki_tag_ids" as "Страхователь: Список признаков д…",
    source_policyholder."user_inspection_id" as "Страхователь: id клиента в систем…",
    source_policyholder."sbs_d_change" as "Страхователь: Дата и время измен…",
    source_policyholder."sberbank_id" as "Страхователь: sberbank_id",
    source_policyholder."d_get_sberbank_id" as "Страхователь: Когда мы получили s…",
    source_policyholder."kfh_head" as "Страхователь: Глава КФХ",
    source_policyholder."authority_termination_legal" as "Страхователь: Орган, внесший зап…",
    source_policyholder."d_termination" as "Страхователь: Дата прекращения",
    source_policyholder."is_termination_info_ul_ip" as "Страхователь: Прекращение ЮЛ/ИП",
    source_policyholder."termination_method" as "Страхователь: Способ прекращения",
    source_policyholder."is_suspense" as "Страхователь: Приостановка (Compliance)",
    source_policyholder."author_str" as "Страхователь: Строковое предста…",
    source_policyholder."client_limits_cause_id" as "Страхователь: Причина",
    source_policyholder."is_ul_sanction_risk" as "Страхователь: Санкционный риск (…",
    source_policyholder."sanction_list" as "Страхователь: Санкционный список",
    source_policyholder."usk_id" as "Страхователь: code_contractor в таблице 1С",
    source_policyholder."citizenship" as "Страхователь: Гражданство",
    source_policyholder."customer_knowledge" as "Страхователь: Код знаний по клие…",
    source_policyholder."is_company_employee" as "Страхователь: Флаг сотрудника СБ…",
    source_policyholder."place_of_birth" as "Страхователь: Место рождения кли…",
    source_policyholder."sts" as "Страхователь: Свидетельство о ре…",
    source_policyholder."sign" as "Страхователь: Флаг контрагента",
    source_policyholder."not_resident_id" as "Страхователь: ID (для нерезидентов)",
    source_policyholder."not_resident_tin" as "Страхователь: TIN (для нерезидентов)",
    source_policyholder."reg_country_id" as "Страхователь: Страна регистрации",
    source_policyholder."for_ins_contact_use" as "Страхователь: Для использования…",
    source_policyholder."vip" as "Страхователь: Флаг VIP-клиента",
    source_policyholder."d_delete" as "Страхователь: Дата логического у…",
    source_policyholder."deleted_user_id" as "Страхователь: id удалившего запись",
    source_policyholder."client_scoring" as "Страхователь: Скоринг клиента",
    source_policyholder."code_uin" as "Страхователь: Код УИН",
    source_policyholder."is_state_organ" as "Страхователь: Государственный о…",
    source_policyholder."kbk" as "Страхователь: КБК",
    source_policyholder."oktmo" as "Страхователь: ОКТМО",
    source_policyholder."is_accredited" as "Страхователь: Аккредитация банка",
    source_policyholder."is_bank" as "Страхователь: Организация являе…",
    source_policyholder."related_retail_crm_status" as "Страхователь: Статус связанного…",
    source_policyholder."group_of_contractor_id" as "Страхователь: Группа контрагентов",
    source_policyholder."client_id" as "Страхователь: ID клиента RetailCRM",
    source_policyholder."crm_sync" as "Страхователь: Синхронизировать…",
    source_policyholder."belong_state_corporation" as "Страхователь: Принадлежит к Гос.…",
    source_policyholder."state_corporation" as "Страхователь: Гос. корпорация",
    source_policyholder."created_from" as "Страхователь: Источник создания",
    source_policyholder."sub_epk_id" as "Страхователь: Саб ЕПК ID",
    source_policyholder."data_new" as "Страхователь: Новая версия данны…",
    source_policyholder."counterparty_identification_status" as "Страхователь: Статус идентифика…",
    source_policyholder."cdi_id" as "Страхователь: ID контрагента в CDI",
    source_request."d_create" as "Заявка: Дата создания записи",
    source_request."active" as "Заявка: Активность",
    source_request."status" as "Заявка: Текущий этап бизнес-проц…",
    source_request."d_change" as "Заявка: Дата последнего изменени…",
    source_request."data_old" as "Заявка: Предыдущая версия данных…",
    source_request."author_remote_addr" as "Заявка: IP адрес автора, создавшег…",
    source_request."id" as "Заявка: ID заявки на страхование",
    source_request."id_broker_request" as "Заявка: ID запроса",
    source_request."d_request" as "Заявка: Дата запроса",
    source_request."author_id" as "Заявка: id автора",
    source_request."responsible_id" as "Заявка: id ответственного",
    source_request."app_annul_reason" as "Заявка: Причина аннулирования за…",
    source_request."app_cancel_reason" as "Заявка: Причина отмены заявки",
    source_request."app_processing_result" as "Заявка: Результат обработки заяв…",
    source_request."orig_letter_subject" as "Заявка: Исходная тема письма",
    source_request."req_curator_id" as "Заявка: Андеррайтер",
    source_request."contract_id" as "Заявка: id договора",
    source_request."contract_not_in_1c" as "Заявка: Договор не найден в 1С",
    source_request."extra_unreq_agree" as "Заявка: Доп. соглашение без перес…",
    source_request."prolong_contract_same_terms" as "Заявка: Пролонгация договора на…",
    source_request."d_send_orig_letter" as "Заявка: Дата и время отправки пис…",
    source_request."d_start_formal" as "Заявка: Дата начала оформления",
    source_request."d_sub_app_reg" as "Заявка: Дата передачи Заявки на о…",
    source_request."create_additional_reason" as "Заявка: Причина создания доп. кар…",
    source_request."ins_company" as "Заявка: Наименование СК",
    source_request."main_request_ins_id" as "Заявка: ID основной карточки",
    source_request."prolong_another_sk" as "Заявка: Пролонгация другой СК",
    source_request."return_reason" as "Заявка: Причина возврата заявки (…",
    source_request."type" as "Заявка: Тип карточки",
    source_request."withdrawal_reason" as "Заявка: Причина отзыва заявки с о…",
    source_request."request_qurator_id" as "Заявка: Оформитель",
    source_request."wiki_tag_ids" as "Заявка: Список признаков для wiki",
    source_request."outsourcing_partner_id" as "Заявка: Партнёр (outsourcing)",
    source_request."outsourcing_partner_services_id" as "Заявка: Услуги партнёра (outsourcing)",
    source_request."quotation_category" as "Заявка: Категория запроса на кот…",
    source_request."sale_channel" as "Заявка: Канал продаж",
    source_request."author_str" as "Заявка: Строковое представление…",
    source_request."business_segment" as "Заявка: Сегмент",
    source_request."orig_letter_sender_email" as "Заявка: Адрес отправителя исходн…",
    source_request."request_initiator_id" as "Заявка: Посредник",
    source_request."d_change_resp_tula_outsource" as "Заявка: Дата передачи в аутсорсинг",
    source_request."is_no_data_and_docs" as "Заявка: Нет данных и документов",
    source_request."corporate_crm_id" as "Заявка: Карточка корп. CRM, из кото…",
    source_request."returning_to_work_reason" as "Заявка: Причина возврата заявки…",
    source_request."deal_probability" as "Заявка: Вероятность сделки",
    source_request."plan_award" as "Заявка: Премия в валюте договора",
    source_request."plan_date_contract" as "Заявка: Дата заключения договора",
    source_request."plan_start_date_contract" as "Заявка: Дата начала действия дог…",
    source_request."refusing_insurance_reason" as "Заявка: Причина отказа от страхо…",
    source_request."is_initiator_not_in_list" as "Заявка: Посредник отсутствует в…",
    source_request."kv" as "Заявка: Размер КВ, %",
    source_request."req_curator_sale_id" as "Заявка: Продавец",
    source_request."award_currency" as "Заявка: Валюта премии",
    source_request."ins_product" as "Заявка: Страховой продукт",
    source_request."pipeline_comment" as "Заявка: Комментарий",
    source_request."pipeline_project_id" as "Заявка: ID проекта в pipeline",
    source_request."d_pipeline_status" as "Заявка: Дата статуса Пайплайн",
    source_request."pipeline_status" as "Заявка: Статус заявки в pipeline",
    source_request."sale_direction" as "Заявка: Направление продаж",
    source_request."business_line" as "Заявка: Линия бизнеса",
    source_request."cause_refusal_sbb" as "Заявка: Причина отказа СББ",
    source_request."is_tender" as "Заявка: Флаг тендерной закупки",
    source_request."currency_rate" as "Заявка: Курс валюты",
    source_request."rub_premium" as "Заявка: Премия в руб.",
    source_request."utm_campaign" as "Заявка: utm_campaign",
    source_request."utm_content" as "Заявка: utm_content",
    source_request."utm_medium" as "Заявка: utm_medium",
    source_request."utm_source" as "Заявка: utm_source",
    source_request."utm_term" as "Заявка: utm_term",
    source_request."create_from" as "Заявка: Создана с",
    source_request."d_currency_rate" as "Заявка: Дата курса валюты",
    source_request."tender_type" as "Заявка: Конкурс/Тендер",
    source_request."is_underwriter_involvement_required" as "Заявка: Требуется участие андерр…",
    source_request."d_ins_contract_expiration" as "Заявка: Дата окончания срока стр…",
    source_request."d_delete" as "Заявка: Дата логического удалени…",
    source_request."deleted_user_id" as "Заявка: id удалившего запись",
    source_request."is_preregistration_contract" as "Заявка: Предварительное оформле…",
    source_request."is_prolong_possible" as "Заявка: Пролонгация возможна",
    source_request."beneficiary_id" as "Заявка: Лизингодатель",
    source_request."main_id" as "Заявка: Заявка на договор",
    source_request."last_request_ins_task_policy_num" as "Заявка: Номер договора/полиса",
    source_request."comments_for_the_client" as "Заявка: Комментарий для клиента",
    source_request."lkul_id" as "Заявка: ID ЛК",
    source_request."lkulmessage_id" as "Заявка: ID интеграционного сообще…",
    source_request."is_accrual_ukv" as "Заявка: Начисление УКВ",
    source_request."ukv" as "Заявка: Размер УКВ, %",
    source_request."role" as "Заявка: Роль",
    source_request."annual_cargo_turnover" as "Заявка: Плановый годовой грузооб…",
    source_request."contract_type" as "Заявка: Вид договора",
    source_request."potential_premium_rub" as "Заявка: Потенциальная страховая…",
    source_request."is_check_sbb_curator" as "Заявка: Проверка куратором СББ",
    source_request."desk" as "Заявка: Деск ПАО",
    source_request."purchase_link" as "Заявка: Ссылка на закупку",
    source_request."tender_id" as "Заявка: Карточка Тендер, из котор…",
    source_request."created_from" as "Заявка: Источник создания",
    source_request."data" as "Заявка: Произвольные данные в JSON…",
    source_request."desk_sbs" as "Заявка: Деск СБС",
    source_request."is_has_pretender_request" as "Заявка: Есть предтендерная заявка",
    source_request."pretender_request_id_for_search" as "Заявка: ID предтендерной заявки",
    source_request."pretender_request_id" as "Заявка: Предтендерная заявка",
    source_request."tender_request_id" as "Заявка: Тендерная заявка",
    source_request."creation_type" as "Заявка: Тип создания",
    source_request."count_years" as "Заявка: Кол-во лет",
    source_request."bool_many_years" as "Заявка: Многолетность",
    source_request."to_send_email" as "Заявка: Рассылка силами продавца",
    source_request."sbs_award" as "Заявка: Премия СБС в руб.",
    source_request."deposit_award" as "Заявка: Депозитная страховая пре…",
    source_request."potencial_award" as "Заявка: Потенциальная премия в в…",
    source_request."deposit_pub_prem" as "Заявка: Депозитная стр… (deposit_pub_prem)",
    source_request."offsetting" as "Заявка: Взаиморасчет",
    source_request."is_insider_information" as "Заявка: Инсайдерская информация",
    source_request."parent_request_ins_id" as "Заявка: Родительская Заявка на д…",
    source_request."is_hand_pipe_general" as "Заявка: Ручная корректировка пай…",
    source_request."trash_is_processing_started" as "Заявка: Обработка начата",
    source_request."trash_is_processing_finished" as "Заявка: Обработка завершена",
    source_request."commercial_proposal_id" as "Заявка: Коммерческое предложение",
    source_request."is_need_related_departments_coordination" as "Заявка: Требуется согласование с…",
    source_request."tipes_of_activity" as "Заявка: Вид (виды) деятельности",
    source_request."outsource" as "Заявка: Описание процессов (аутс…",
    source_request."prof_activity" as "Заявка: Описание профессиональн…",
    source_request."insurer" as "Заявка: Страховщик",
    source_request."adinsure_product" as "Заявка: Продукт Adinsure",
    source_request."range_insured_sum" as "Заявка: Диапазон страховой суммы",
    source_request."insurance_amount" as "Заявка: Страховая сумма",
    source_request."comment_object_type" as "Заявка: Комментарий к типу объекта",
    source_request."comment_gross_tariff" as "Заявка: Комментарий к брутто-тар…",
    source_request."currency_comment" as "Заявка: Комментарий к валюте",
    source_request."agents_comment" as "Заявка: Доп. комментарий агента",
    source_request."ukv_rub" as "Заявка: ukv",
    source_request."kv_rub" as "Заявка: kv_rub",
    source_request."sum_ukv_kv" as "Заявка: sum_ukv_kv",
    source_request."sum_ukv_kv_rub" as "Заявка: sum_ukv_kv_rub",
    source_request."policy_count" as "Заявка: policy_count",
    source_request."property_subj_morgage" as "Заявка: Имущество является предм…",
    source_request."d_contract_release" as "Заявка: Дата выпуска Договора в УС",
    source_request."business_segment_inn" as "Заявка: ИНН для сегментации",
    source_request."agents_recommendations" as "Заявка: Рекомендации агента",
    source_request."business_id" as "Заявка: Сквозной Бизнес-ID предло…",
    source_task."d_create" as "Задача: Дата создания записи",
    source_task."active" as "Задача: Активность",
    source_task."status" as "Задача: Текущий этап бизнес-проц…",
    source_task."d_change" as "Задача: Дата последнего изменени…",
    source_task."data" as "Задача: Произвольные данные в JSON…",
    source_task."author_remote_addr" as "Задача: IP адрес автора, создавшег…",
    source_task."id" as "Задача: ID задачи по заявке",
    source_task."task_type" as "Задача: Наименование задачи",
    source_task."quotation_category" as "Задача: Категория запроса на кот…",
    source_task."result" as "Задача: Результат задачи",
    source_task."insurer_title" as "Задача: Наименование Страховате…",
    source_task."insurer_action_type" as "Задача: Род деятельности",
    source_task."insurer_inn" as "Задача: ИНН",
    source_task."bank_guarantee" as "Задача: Залог Банка",
    source_task."items_owner" as "Задача: Владельцы объектов или э…",
    source_task."items_user" as "Задача: Эксплуатант предметов, з…",
    source_task."net_fare" as "Задача: Нетто тариф, %",
    source_task."add_conditions" as "Задача: Примечания и доп. условия",
    source_task."brutto_fare_recommend" as "Задача: Брутто тариф (рекомендов…",
    source_task."kv" as "Задача: КВ",
    source_task."deductible" as "Задача: Франшиза (общая по котиро…",
    source_task."deductible_type" as "Задача: Тип франшизы",
    source_task."s_deductible" as "Задача: Размер франшизы",
    source_task."ins_territory" as "Задача: Территория страхования",
    source_task."d_insurance_start" as "Задача: Дата начала договора",
    source_task."d_insurance_end" as "Задача: Дата окончания договора",
    source_task."request_ins_id" as "Задача: Заявка на страхование",
    source_task."author_id" as "Задача: id автора",
    source_task."responsible_id" as "Задача: id ответственного",
    source_task."contract_num_policy" as "Задача: Номер договора/полиса",
    source_task."d_conclusion_ins_contract" as "Задача: Дата заключения Договора…",
    source_task."d_document" as "Задача: Дата заключения доп. согл…",
    source_task."d_end_action_agreement" as "Задача: Дата окончания доп. согла…",
    source_task."d_start_action_agreement" as "Задача: Дата начала доп. соглашен…",
    source_task."ins_document_num" as "Задача: Номер доп. соглашения",
    source_task."ins_document_type" as "Задача: Тип документа",
    source_task."prev_contract_num_policy" as "Задача: Номер предыдущего догово…",
    source_task."ins_refuse" as "Задача: Отказ в принятии на страх…",
    source_task."orig_letter_subject" as "Задача: Тема исходного письма",
    source_task."refuse_reason" as "Задача: Комментарий к причине от…",
    source_task."region_id" as "Задача: Регион (субъект) РФ",
    source_task."tariff_calculation" as "Задача: Вариант расчёта тарифа",
    source_task."d_ins_app" as "Задача: Дата заявления на страхо…",
    source_task."ins_app_form" as "Задача: Форма заявления на догов…",
    source_task."ins_premium_pay_order" as "Задача: Порядок оплаты страховой…",
    source_task."contract_franchise_amount" as "Задача: Размер франшизы по догов…",
    source_task."contract_type_franchise" as "Задача: Тип франшизы по договору",
    source_task."ins_condition" as "Задача: Условия страхования",
    source_task."ins_contract_1_3" as "Задача: Пункт 1.3 Договора страхов…",
    source_task."ins_contract_1_4" as "Задача: Пункт 1.4 Договора страхов…",
    source_task."ins_product" as "Задача: Страховой продукт",
    source_task."parties_under_ins_contract" as "Задача: Стороны по договору стра…",
    source_task."property_subj_morgage" as "Задача: Имущество является предм…",
    source_task."ins_kv" as "Задача: КВ (ins_kv)",
    source_task."d_full_pack" as "Задача: Дата получения полного п…",
    source_task."task_annul_reason" as "Задача: Причина аннулирования за…",
    source_task."task_cancel_reason" as "Задача: Причина отмены задачи",
    source_task."wiki_tag_ids" as "Задача: Список признаков для wiki",
    source_task."brutto_fare_winning_quotes" as "Задача: Брутто тариф победившей…",
    source_task."d_receipt_winning_quotes" as "Задача: Дата получения победивше…",
    source_task."d_terminate" as "Задача: Дата расторжения",
    source_task."d_transaction" as "Задача: Дата операции или транза…",
    source_task."email_for_send_scans" as "Задача: E-mail Клиента",
    source_task."ins_amount_winning_quotes" as "Задача: Страховая сумма победивш…",
    source_task."ins_contract_form" as "Задача: Форма договора страхован…",
    source_task."ins_contract_premium_no_add" as "Задача: Страховая премия по дого…",
    source_task."ins_premium_premium" as "Задача: Сумма доплаты страховой…",
    source_task."ins_premium_return" as "Задача: Сумма возврата страховой…",
    source_task."ins_sum_exclude_franchise" as "Задача: Страховая сумма (без учёт…",
    source_task."ins_sum_under_contract_no_add_agree" as "Задача: Страховая сумма по догов…",
    source_task."is_sbs_win_quote" as "Задача: Котировка выиграна СБС",
    source_task."is_use_franchise_ins_sum" as "Задача: Учитывать франшизу в стр…",
    source_task."kv_amount" as "Задача: Размер КВ (сумма)",
    source_task."method_calc" as "Задача: Способ расчёта",
    source_task."net_fare_winning_quotes" as "Задача: Нетто-тариф победившей к…",
    source_task."net_rate_calculation" as "Задача: Нетто-тариф (для расчёта)",
    source_task."reg_contract_method" as "Задача: Способ оформления догово…",
    source_task."reins_protect" as "Задача: Параметры перестраховоч…",
    source_task."rvd" as "Задача: РВД",
    source_task."sale_channel" as "Задача: Канал продаж",
    source_task."total_ins_amount_for_add_agree" as "Задача: Общая с… (total_ins_amount_for_add_agree)",
    source_task."transaction_id" as "Задача: ID сделки",
    source_task."undewriter_method" as "Задача: Способ андеррайтинга",
    source_task."deal_status" as "Задача: Статус сделки",
    source_task."deal_region" as "Задача: Регион сделки (подраздел…",
    source_task."deal_type" as "Задача: Тип сделки",
    source_task."outsourcing_partner_id" as "Задача: Партнёр (outsourcing)",
    source_task."outsourcing_partner_services_id" as "Задача: Услуги партнёра (outsourcing)",
    source_task."spec_program" as "Задача: Спецпрограмма",
    source_task."author_str" as "Задача: Строковое представление…",
    source_task."application_add_aggreement_form" as "Задача: Форма заявления на доп. с…",
    source_task."d_application_add_aggreement" as "Задача: Дата заявления на доп. со…",
    source_task."d_end_reins" as "Задача: Дата окончания перестрах…",
    source_task."d_start_reins" as "Задача: Дата начала перестрахова…",
    source_task."ins_program_package" as "Задача: Программа/пакет страхова…",
    source_task."ratsp" as "Задача: РАТСП",
    source_task."approval_result" as "Задача: Результат согласования",
    source_task."check_comments" as "Задача: Замечания/причина отказа…",
    source_task."check_result" as "Задача: Результат проверки",
    source_task."verification_basis" as "Задача: Основание для проверки",
    source_task."who_checks" as "Задача: Кто проверяет",
    source_task."request_ins_task_id" as "Задача: Задача на основании кото…",
    source_task."is_resident" as "Задача: Резидент",
    source_task."not_resident_id" as "Задача: ID (для нерезидентов)",
    source_task."not_resident_tin" as "Задача: TIN (для нерезидентов)",
    source_task."reg_country_id" as "Задача: Страна регистрации",
    source_task."d_fill_ship_addr_post" as "Задача: Дата добавления адреса",
    source_task."trade_credit_ins_contract_id" as "Задача: на основании которого со…",
    source_task."insurance_premiums_number" as "Задача: Кол-во страховых взносов",
    source_task."num" as "Задача: Счетчик номера договора",
    source_task."trade_credit_lim_req_mon_id" as "Задача: на основ… (trade_credit_lim_req_mon_id)",
    source_task."cached_mask_id" as "Задача: ID маски",
    source_task."is_clone" as "Задача: Является клоном",
    source_task."comment_field" as "Задача: Комментарий к отправке",
    source_task."is_dops_number_manually" as "Задача: Номер доп. соглашения вру…",
    source_task."is_update_needed" as "Задача: Обновление",
    source_task."ins_price" as "Задача: Страховая стоимость (кот…",
    source_task."ins_sum" as "Задача: Страховая сумма (котиров…",
    source_task."ins_sum_whithout_deductible" as "Задача: Страховая сумма (без учет…",
    source_task."is_cons_deductible_ins_sum" as "Задача: Учитывать франшизу в сум…",
    source_task."netto_prem" as "Задача: Премия нетто",
    source_task."payment_method" as "Задача: Способ расчета (котировка)",
    source_task."currency_by_quote" as "Задача: Валюта по котировке",
    source_task."application_form_for_accompanying_document" as "Задача: Форма заявления на сопро…",
    source_task."document_title" as "Задача: Наименование документа",
    source_task."d_delete" as "Задача: Дата логического удалени…",
    source_task."deleted_user_id" as "Задача: id удалившего запись",
    source_task."attachment_ins_premium" as "Задача: Страховая премия (прилож…",
    source_task."attachment_ins_sum" as "Задача: Страховая сумма (приложе…",
    source_task."attachment_num" as "Задача: Номер приложения",
    source_task."d_attachment_conclusion" as "Задача: Дата заключения приложен…",
    source_task."d_end_attachment" as "Задача: Дата окончания действия…",
    source_task."d_start_attachment" as "Задача: Дата начала действия при…",
    source_task."declaration_form_attachment" as "Задача: Форма заявления (приложе…",
    source_task."ds_num_excluding" as "Задача: Номер ДС без учета",
    source_task."shipment_days" as "Задача: Срок перевозки (дни)",
    source_task."d_first_autoloading_required" as "Задача: Дата снятия первого Подл…",
    source_task."is_autoloading_required" as "Задача: Подлежит автозагрузке",
    source_task."d_insurance_cover_end" as "Задача: Дата окончания страховог…",
    source_task."currency_app" as "Задача: Валюта (приложение)",
    source_task."franchise_size_application" as "Задача: Размер франшизы (приложе…",
    source_task."franchise_type_application" as "Задача: Тип франшизы (приложение)",
    source_task."d_insurance_cover_start" as "Задача: Дата начала страхового п…",
    source_task."days_apkl" as "Задача: АПКЛ (дни)",
    source_task."days_credit_period" as "Задача: Кредитный период (дни)",
    source_task."days_notification_period" as "Задача: Период уведомления (дни)",
    source_task."days_wait_period" as "Задача: Период ожидания (дни)",
    source_task."industry" as "Задача: Отрасль",
    source_task."is_only_add_payment" as "Задача: Только доплата",
    source_task."subindustry" as "Задача: Подотрасль",
    source_task."bg_policy_num" as "Задача: Номер БГ",
    source_task."bg_purchase_num" as "Задача: Номер закупки по БГ",
    source_task."principal_id" as "Задача: Принципал по БГ",
    source_task."d_pipeline_status" as "Задача: Дата Статуса Пайплайн (пр…",
    source_task."pipeline_status" as "Задача: Статус Пайплайн (приложе…",
    source_task."contract_type" as "Задача: Вид договора",
    source_task."general_policy_ds_attachment_ins_premium" as "Задача: О… (general_policy_ds_attachment_ins_premium)",
    source_task."general_policy_ds_attachment_ins_sum" as "Задача: Общ… (general_policy_ds_attachment_ins_sum)",
    source_task."refund_attachment_ins_premium" as "Задача: Сумма в… (refund_attachment_ins_premium)",
    source_task."surcharge_attachment_ins_premium" as "Задача: Сумма… (surcharge_attachment_ins_premium)",
    source_task."adinsure_product" as "Задача: Продукт Adinsure",
    source_task."can_manual_fill_amount" as "Задача: Заполнить вручную",
    source_task."locations_count" as "Задача: Кол-во локаций",
    source_task."multi_location" as "Задача: Многолокационный",
    source_task."task_annual_cargo_turnover" as "Задача: Плановый годовой грузооб…",
    source_task."is_living_space_nsis" as "Задача: Жилое помещение (для НСИС)",
    source_task."trade_credit_ins_contract_contract_with_retrodates" as "Задача: Документ с ретродатами",
    source_task."created_from" as "Задача: Источник создания",
    source_task."exposition" as "Задача: Экспозиция",
    source_task."verification_by_curator_sbb" as "Задача: Проверка куратором СББ",
    source_task."is_receipts_calculator_received" as "Задача: Получен расчёт калькулят…",
    source_task."ins_premium_calculator" as "Задача: Страховая премия (кальку…",
    source_task."object_description" as "Задача: Описание объекта страхов…",
    source_task."is_included_warehouse_clause" as "Задача: Включена Складская огово…",
    source_task."creation_type" as "Задача: Тип создания",
    source_task."contract_autorenewal_month" as "Задача: Срок автопролонгации дог…",
    source_task."bool_many_years" as "Задача: Многолетность",
    source_task."number_days_bordereau_declaration_payment" as "Задача: Кол-во дней для оплаты бо…",
    source_task."is_retention_amount" as "Задача: Риски на собственном уде…",
    source_task."has_underwriting_directive" as "Задача: Приказ",
    source_task."underwriting_directive" as "Задача: Значение Приказ",
    source_task."has_kskb" as "Задача: КСКБ",
    source_task."kskb" as "Задача: Значение КСКБ",
    source_task."is_ins_obligatory" as "Задача: Облигаторное перестрахо…",
    source_task."is_special_accept" as "Задача: СпецАкцепт",
    source_task."is_ins_facultative" as "Задача: Факультативное перестра…",
    source_task."is_oblig_program_facultative" as "Задача: Факультативно-облигатор…",
    source_task."is_terror_facility" as "Задача: Террористическая Facility",
    source_task."is_drilling_facility" as "Задача: Буровая Facility",
    source_task."is_ratsp_fop" as "Задача: РАТСП ФОП",
    source_task."is_special_accept_fop" as "Задача: СпецАкцепт ФОП",
    source_task."facultative_reason" as "Задача: Комментарий-обоснование…",
    source_task."contract_num_policy_1c" as "Задача: Номер договора из 1С",
    source_task."request_num_lk" as "Задача: Номер заявки ЛК",
    source_task."carrier_title" as "Задача: Наименование Перевозчик…",
    source_task."inn" as "Задача: ИНН (inn)",
    source_task."availability_mdp" as "Задача: Наличие МДП",
    source_task."min_dep_prem" as "Задача: Минимальная депозитная п…",
    source_task."insurance_object_purpose" as "Задача: Назначение объекта страх…",
    source_task."insurance_object_other_purpose" as "Задача: Иное назначение объекта…",
    source_task."work_nature" as "Задача: Характер проводимых работ",
    source_task."other_work_nature" as "Задача: Иной характер проводимых…",
    source_task."construction_permit_availability" as "Задача: Наличие разрешения на ст…",
    source_task."object_readiness_at_insurance_date" as "Задача: Степень готовности объек…",
    source_task."request_reinsurance_id" as "Задача: Заявка на перестрахование",
    source_task."franchise_insured_value" as "Задача: Страховая стоимость (общ…",
    source_task."franchise_ins_sum" as "Задача: Страховая сум… (franchise_ins_sum)",
    source_task."deposit_award" as "Задача: Депозитная страховая пре…",
    source_task."deposit_pub_prem" as "Задача: Депозитная стр… (deposit_pub_prem)",
    source_task."potencial_award" as "Задача: Потенциальная страховая…",
    source_task."potential_premium_rub" as "Задача: Потенциальн… (potential_premium_rub)",
    source_task."annual_cargo_turnover" as "Задача: Плановый го… (annual_cargo_turnover)",
    source_task."currency_by_general_cargo" as "Задача: Валюта по генеральному д…",
    source_task."task_annual_cargo_turnover_for_add_agree" as "Задача: Плановый грузооборот по…",
    source_task."quote_currency" as "Задача: Валюта котировки",
    source_task."insured_amount" as "Задача: Страховая сумма… (insured_amount)",
    source_task."potential_premium_by_quote" as "Задача: Потенциальная премия в в…",
    source_task."potential_premium" as "Задача: Потенциальная… (potential_premium)",
    source_task."insurer_ins_sum" as "Задача: Страховая премия Страхов…",
    source_task."tipes_of_activity" as "Задача: Вид (виды) деятельности",
    source_task."outsource" as "Задача: Описание процессов (аутс…",
    source_task."prof_activity" as "Задача: Описание профессиональн…",
    source_task."is_terrorist_obligator" as "Задача: Террористический облига…",
    source_task."client_loss_history" as "Задача: Информация об убытках по…",
    source_task."notification_type" as "Задача: Тип уведомления",
    source_task."insurance_application_form" as "Задача: Форма заявления на страх…",
    source_task."sro_title_id" as "Задача: Наименование СРО",
    source_task."policyholder_reg_num_in_sro_register" as "Задача: Рег.№ Страхователя в рее…",
    source_task."sro_join_date" as "Задача: Дата вступления в СРО",
    source_task."sro_membership_choices" as "Задача: Членство в СРО",
    source_task."signature_LK" as "Задача: ФИО подписанта ЛК",
    source_task."signature_position_LK" as "Задача: Должность подписанта ЛК",
    source_task."is_special_accept_to" as "Задача: СпецАкцепт ТО",
    source_task_object."parent_id" as "Связь задачи и объекта: ID родител…",
    source_task_object."characteristics_id" as "Связь задачи и объекта: None",
    source_task_object."id" as "Связь задачи и объекта: ID объекта…",
    source_task_object."d_create" as "Связь задачи и объекта: Дата созд…",
    source_task_object."d_change" as "Связь задачи и объекта: Дата изме…",
    source_task_object."data" as "Связь задачи и объекта: Кастомны…",
    source_task_object."object_group_id" as "Связь задачи и объекта: Группа об…",
    source_contract."d_create" as "Договор: Дата создания записи",
    source_contract."active" as "Договор: Активность",
    source_contract."status" as "Договор: Текущий этап бизнес-про…",
    source_contract."d_change" as "Договор: Дата последнего изменен…",
    source_contract."data_old" as "Договор: Предыдущая версия данны…",
    source_contract."id" as "Договор: ID договора",
    source_contract."n_contract" as "Договор: Номер договора",
    source_contract."id_addcontract" as "Договор: id доп. соглашения",
    source_contract."n_addcontract" as "Договор: Номер доп. соглашения",
    source_contract."addcontract_type" as "Договор: Тип доп. соглашения",
    source_contract."document_status" as "Договор: Статус документа",
    source_contract."document_state" as "Договор: Этап документа",
    source_contract."d_sign_addcontract" as "Договор: Дата подписания доп. сог…",
    source_contract."agent_contract_name" as "Договор: Агент по договору",
    source_contract."currency" as "Договор: Валюта договора",
    source_contract."obj_address" as "Договор: Адрес объекта страхован…",
    source_contract."tb_name" as "Договор: tb_name",
    source_contract."bankbranch_name" as "Договор: bankbranch_name",
    source_contract."office_name" as "Договор: office_name",
    source_contract."n_loss_contract" as "Договор: Кол-во убытков по догово…",
    source_contract."if_activation" as "Договор: if_activation",
    source_contract."sbs_id" as "Договор: id_contract СБС",
    source_contract."data_hash" as "Договор: Контрольная сумма догов…",
    source_contract."contractor_id" as "Договор: Страхователь",
    source_contract."author_id" as "Договор: id автора",
    source_contract."responsible_id" as "Договор: id ответственного",
    source_contract."id_contractor" as "Договор: id контрагента sbs",
    source_contract."manager" as "Договор: manager",
    source_contract."region" as "Договор: region",
    source_contract."author_remote_addr" as "Договор: IP адрес автора, создавше…",
    source_contract."ins_product_sbs" as "Договор: Страховой продукт в СБС",
    source_contract."wiki_tag_ids" as "Договор: Список признаков для wiki",
    source_contract."sbs_d_change" as "Договор: Дата и время изменения з…",
    source_contract."amount_payment" as "Договор: amount_payment",
    source_contract."comment" as "Договор: Комментарий",
    source_contract."d_payment" as "Договор: Дата платежа",
    source_contract."kit_status" as "Договор: Статус комплекта",
    source_contract."number_payment" as "Договор: Платёжное поручение",
    source_contract."author_str" as "Договор: Строковое представлени…",
    source_contract."perc_kv_contract" as "Договор: КВ агента по договору",
    source_contract."n_contract_cleaned" as "Договор: Номер договора (нормали…",
    source_contract."addcontract_chain_num" as "Договор: Номер доп соглашения в ц…",
    source_contract."addition_premium" as "Договор: Дополнительная страхов…",
    source_contract."contract_series" as "Договор: Серия договора",
    source_contract."d_active_contract" as "Договор: Дата вступления в силу",
    source_contract."d_termination" as "Договор: Дата досрочного прекращ…",
    source_contract."prevcontract_id" as "Договор: ID предыдущего договора",
    source_contract."rootcontract_id" as "Договор: ID основного договора",
    source_contract."rsa_contract_id" as "Договор: ID договора в RSA",
    source_contract."gross_premium_motor" as "Договор: Начисленная премия (мот…",
    source_contract."system_type" as "Договор: Система-источник",
    source_contract."sbs_type_insurance" as "Договор: Тип страхования в 1C",
    source_contract."d_sign_contract" as "Договор: Дата подписания договора",
    source_contract."d_start_contract" as "Договор: Дата начала договора",
    source_contract."d_end_contract" as "Договор: Дата окончания договора",
    source_contract."calc_id" as "Договор: ID расчета в страховом ко…",
    source_contract."ins_program" as "Договор: Программа страхования",
    source_contract."ins_quote_id" as "Договор: ID котировки в страховом…",
    source_contract."is_expansion_territory" as "Договор: Расширение территории с…",
    source_contract."revise_ins_regulation" as "Договор: Редакция правил",
    source_contract."d_of_reflection_in_accounting" as "Договор: Дата БУ",
    source_contract."isreinsured" as "Договор: Флаг перестрахования",
    source_contract."facultative_reinsurance_contract" as "Договор: Договор факультативног…",
    source_contract."d_delete" as "Договор: Дата логического удален…",
    source_contract."deleted_user_id" as "Договор: id удалившего запись",
    source_contract."reason_termination" as "Договор: Причина расторжения",
    source_contract."general_agreement_id" as "Договор: ID генерального соглашен…",
    source_contract."filled_retail_task_id" as "Договор: Заполненная данными Retail…",
    source_contract."holding_id" as "Договор: Холдинг",
    source_contract."general_agreement_id_ga" as "Договор: ИД в 1С",
    source_contract."virtu_id" as "Договор: Id из Virtu",
    source_contract."obj_address_city" as "Договор: Город объекта",
    source_contract."obj_address_house_number" as "Договор: Дом объекта",
    source_contract."obj_address_korpus" as "Договор: Корпус объекта",
    source_contract."obj_address_region" as "Договор: Регион объекта",
    source_contract."obj_address_street" as "Договор: Улица объекта",
    source_contract."obj_address_stroenie" as "Договор: Строение объекта",
    source_contract."obj_address_vladenie" as "Договор: Владение объекта",
    source_contract."standart_city" as "Договор: Структурированный город",
    source_contract."standart_house_number" as "Договор: Структурированный дом",
    source_contract."standart_obj_address" as "Договор: Структурированный адрес",
    source_contract."standart_region" as "Договор: Структурированный регион",
    source_contract."standart_street" as "Договор: Структурированная улица",
    source_contract."tender_agreement" as "Договор: Тендерный договор",
    source_contract."formatted_obj_address" as "Договор: Форматированный адрес с…",
    source_contract."sales_channel" as "Договор: Канал продаж",
    source_contract."created_from" as "Договор: Источник создания",
    source_contract."data" as "Договор: Произвольные данные в JSO…",
    source_contract."ecm_id" as "Договор: ID документа в ECM",
    source_contract."d_ecm_sync" as "Договор: Дата и время синхрониза…",
    source_contract."core_id" as "Договор: ID договора в основной си…",
    source_contract."cred_num_dog" as "Договор: Номер кредитного догово…",
    source_contract."cred_d_give" as "Договор: Дата кредитного договора",
    source_contract."cred_status" as "Договор: Статус кредитного догов…"
from ranked_addresses duplicate
join objects_prepared_for_egrn object_rows
    on object_rows.address_match_key = duplicate.address_match_key
left join exact_address_stats exact
    on exact.exact_address_match_key = object_rows.exact_address_match_key
left join bps_request_ins_task source_task
    on source_task.id = object_rows.task_id
left join bps_request_ins source_request
    on source_request.id = object_rows.request_id
left join bps_contract source_contract
    on source_contract.id = object_rows.contract_id
left join bps_request_ins_task_insurance_object source_task_object
    on source_task_object.id = object_rows.task_object_link_id
left join base_insurance_object_characteristics source_characteristics
    on source_characteristics.id = object_rows.characteristics_id
left join base_insurance_object source_insurance_object
    on source_insurance_object.id = object_rows.object_id
left join base_geo_address source_address
    on source_address.id = object_rows.geo_address_id
left join bps_contractor source_policyholder
    on source_policyholder.id = object_rows.policyholder_id
left join lateral (
    select
        count(*) as condition_row_count,
        count(*) filter (
            where condition.insured_sum is not null
        ) as rows_with_insured_sum,
        count(distinct condition.insured_sum) filter (
            where condition.insured_sum is not null
        ) as distinct_insured_sum_count,
        min(condition.insured_sum) as minimum_insured_sum,
        max(condition.insured_sum) as maximum_insured_sum,
        string_agg(
            distinct condition.insured_sum_currency,
            ', '
            order by condition.insured_sum_currency
        ) filter (
            where condition.insured_sum_currency is not null
        ) as insured_sum_currencies,
        min(condition.per_occurance_limit)
            as minimum_per_occurrence_limit,
        max(condition.per_occurance_limit)
            as maximum_per_occurrence_limit,
        jsonb_agg(
            to_jsonb(condition)
            order by
                condition.terms_option_number nulls last,
                condition.id
        ) as all_condition_rows
    from base_insurance_object_conditions condition
    where condition.characteristics_id = object_rows.characteristics_id
) source_conditions
    on true
order by
    duplicate.address_group_number,
    object_rows.policyholder_id,
    object_rows.contract_id,
    object_rows.object_id;
