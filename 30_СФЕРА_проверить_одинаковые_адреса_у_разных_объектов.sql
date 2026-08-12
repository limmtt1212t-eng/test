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
*/

with task_candidates as (
select
    contract.id as contract_id,
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
    object_rows.contract_number as "Номер договора",
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
    object_rows.address_source as "Откуда взят адрес",
    object_rows.address_for_egrn_search as "Адрес Сферы для поиска",
    object_rows.source_address as "Адрес-источник до разбора",
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
    object_rows.fias_code as "ФИАС из Сферы",
    object_rows.longitude as "Долгота",
    object_rows.latitude as "Широта",
    object_rows.address_dgis_id as "ID адреса 2ГИС",
    object_rows.object_name as "Название объекта",
    object_rows.object_type as "Тип объекта",
    object_rows.elementary_obj_type as "Системный тип объекта",
    object_rows.object_description as "Описание объекта",
    object_rows.area_raw as "Площадь как записана",
    object_rows.area_numeric as "Площадь числом",
    object_rows.insurance_value as "Страховая стоимость",
    object_rows.task_object_insured_sum as "Страховая сумма по объекту",
    object_rows.is_pledged as "Признак залога",
    object_rows.insurance_territory as "Территория страхования",
    object_rows.insured_components as "Что застраховано",
    object_rows.activity_types as "Виды деятельности",
    object_rows.risk_natures as "Характеры риска",
    object_rows.characteristics_version_number as "Номер версии характеристик",
    object_rows.characteristics_version_start as "Начало версии характеристик",
    object_rows.characteristics_version_end as "Окончание версии характеристик",
    object_rows.characteristics_version_is_active as "Активная версия",
    object_rows.object_created_at as "Дата создания объекта",
    object_rows.object_changed_at as "Дата изменения объекта"
from ranked_addresses duplicate
join objects_prepared_for_egrn object_rows
    on object_rows.address_match_key = duplicate.address_match_key
order by
    duplicate.address_group_number,
    object_rows.policyholder_id,
    object_rows.contract_id,
    object_rows.object_id;
