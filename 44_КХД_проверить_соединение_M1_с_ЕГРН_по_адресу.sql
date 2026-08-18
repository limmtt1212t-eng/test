/*
Проверка соединения датасета модели 1 с ЕГРН по адресу.

Запускать в Oracle.

Результат содержит одну строку на объект Сферы. Данные ЕГРН заполняются
только тогда, когда по адресу найден один кадастровый объект.

Для поиска используются населённый пункт, улица и дом. Корпус, строение,
квартира, офис, комната или помещение учитываются, если они указаны.
Индекс и регион сравниваются, если они заполнены с обеих сторон.
Площадь выводится рядом для проверки, но в соединении пока не участвует.

Если загруженная таблица называется иначе, нужно изменить её название
только в CTE sphere_source.
*/

with sphere_source as (
    /* Берём только поля, которые нужны для проверки соединения. */
    select /*+ materialize */
        rowidtochar(s.rowid) as sphere_row_id,
        s.contract_id,
        s.contract_number,
        s.task_id,
        s.task_object_link_id,
        s.characteristics_id,
        s.object_id,
        s.geo_address_id,
        s.real_estate_objects_in_contract,
        cast(s.object_description as varchar2(4000))
            as object_description,
        s.total_area,
        cast(s.full_address as varchar2(4000)) as full_address,
        cast(s.original_address as varchar2(4000)) as original_address,
        s.postal_code,
        s.settlement,
        s.street,
        s.house,
        s.building,
        s.block,
        s.flat,
        s.office
    from SVETOVAVS.SPHERE_M1_STAGE_18_08_2026 s
),

sphere_text as (
    /* Если нормализованного адреса нет, используем адрес, введённый вручную. */
    select
        s.*,
        coalesce(
            nullif(trim(s.full_address), ''),
            nullif(trim(s.original_address), '')
        ) as source_address,
        regexp_replace(
            regexp_replace(
                replace(
                    lower(
                        replace(
                            coalesce(
                                nullif(trim(s.full_address), ''),
                                nullif(trim(s.original_address), '')
                            ),
                            chr(160),
                            ' '
                        )
                    ),
                    'ё',
                    'е'
                ),
                '[;|]+',
                ','
            ),
            '[[:space:]]*,[[:space:]]*',
            ', '
        ) as address_text
    from sphere_source s
),

sphere_parts_raw as (
    /* Берём готовые части адреса, а при их отсутствии разбираем полный адрес. */
    select
        s.*,
        coalesce(
            nullif(trim(s.postal_code), ''),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*([0-9]{6})([[:space:]]*,|$)',
                1, 1, 'i', 2
            )
        ) as postal_code_raw,
        regexp_substr(
            s.address_text,
            '(^|,)[[:space:]]*([^,]*(область|обл[.]?|край|республика|респ[.]?)[^,]*)',
            1, 1, 'i', 2
        ) as region_raw,
        coalesce(
            nullif(trim(s.settlement), ''),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(город|г)[.]?[[:space:]]+([^,]+)',
                1, 1, 'i', 3
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(пгт|поселок городского типа|рабочий поселок|рп|поселок|пос|село|с|деревня|д)[.]?[[:space:]]+([^,]+)',
                1, 1, 'i', 3
            )
        ) as locality_raw,
        coalesce(
            nullif(trim(s.street), ''),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(улица|ул[.]?|проспект|пр-кт|переулок|пер[.]?|шоссе|ш[.]?|набережная|наб[.]?|бульвар|б-р|проезд|площадь|пл[.]?|тракт|аллея)[[:space:]]+([^,]+)',
                1, 1, 'i', 3
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*([^,]+)[[:space:]]+(улица|ул[.]?|проспект|пр-кт|переулок|пер[.]?|шоссе|ш[.]?|набережная|наб[.]?|бульвар|б-р|проезд|площадь|пл[.]?|тракт|аллея)([[:space:]]*,|$)',
                1, 1, 'i', 2
            )
        ) as street_raw,
        coalesce(
            nullif(trim(s.house), ''),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(дом|д)[.]?[[:space:]]*([0-9]+[а-яa-z]?([/-][0-9а-яa-z]+)?)',
                1, 1, 'i', 3
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*([0-9]{1,5}[а-яa-z]?([/-][0-9а-яa-z]+)?)([[:space:]]*,|$)',
                1, 1, 'i', 2
            )
        ) as house_raw,
        coalesce(
            nullif(trim(s.block), ''),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(корпус|корп|к)[.]?[[:space:]]*([0-9а-яa-z/-]+)',
                1, 1, 'i', 3
            )
        ) as korpus_raw,
        coalesce(
            nullif(trim(s.building), ''),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(строение|стр)[.]?[[:space:]]*([0-9а-яa-z/-]+)',
                1, 1, 'i', 3
            )
        ) as stroenie_raw,
        case
            when regexp_like(
                s.address_text,
                '(^|,)[[:space:]]*(квартира|кв)[.]?[[:space:]]+',
                'i'
            ) then 'Квартира'
            when regexp_like(
                s.address_text,
                '(^|,)[[:space:]]*(офис|оф)[.]?[[:space:]]+',
                'i'
            ) then 'Офис'
            when regexp_like(
                s.address_text,
                '(^|,)[[:space:]]*(комната|комн)[.]?[[:space:]]+',
                'i'
            ) then 'Комната'
            when regexp_like(
                s.address_text,
                '(^|,)[[:space:]]*(помещение|пом)[.]?[[:space:]]+',
                'i'
            ) then 'Помещение'
            when nullif(trim(s.office), '') is not null then 'Офис'
            when nullif(trim(s.flat), '') is not null then 'Квартира'
        end as unit_type_raw,
        coalesce(
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(квартира|кв)[.]?[[:space:]]*([^,]+)',
                1, 1, 'i', 3
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(офис|оф)[.]?[[:space:]]*([^,]+)',
                1, 1, 'i', 3
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(комната|комн)[.]?[[:space:]]*([^,]+)',
                1, 1, 'i', 3
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(помещение|пом)[.]?[[:space:]]*([^,]+)',
                1, 1, 'i', 3
            ),
            nullif(trim(s.office), ''),
            nullif(trim(s.flat), '')
        ) as unit_raw
    from sphere_text s
),

sphere_prepared as (
    /* Приводим части адреса к одному виду для сравнения. */
    select /*+ materialize */
        s.*,
        regexp_replace(s.postal_code_raw, '[^0-9]+', '')
            as sphere_postal_code,
        regexp_replace(
            regexp_replace(
                replace(lower(trim(s.region_raw)), 'ё', 'е'),
                '(^|[[:space:]])(область|обл|край|республика|респ)([.]|[[:space:]]|$)',
                ' '
            ),
            '[^[:alnum:]]+',
            ''
        ) as sphere_region,
        regexp_replace(
            regexp_replace(
                replace(lower(trim(s.locality_raw)), 'ё', 'е'),
                '(^|[[:space:]])(город|г|пгт|поселок городского типа|рабочий поселок|рп|поселок|пос|село|с|деревня|д)([.]|[[:space:]]|$)',
                ' '
            ),
            '[^[:alnum:]]+',
            ''
        ) as sphere_locality,
        regexp_replace(
            regexp_replace(
                replace(lower(trim(s.street_raw)), 'ё', 'е'),
                '(^|[[:space:]])(улица|ул|проспект|пр-кт|переулок|пер|шоссе|ш|набережная|наб|бульвар|б-р|проезд|площадь|пл|тракт|аллея)([.]|[[:space:]]|$)',
                ' '
            ),
            '[^[:alnum:]]+',
            ''
        ) as sphere_street,
        regexp_replace(
            replace(lower(trim(s.house_raw)), 'ё', 'е'),
            '[^[:alnum:]]+',
            ''
        ) as sphere_house,
        regexp_replace(
            replace(lower(trim(s.korpus_raw)), 'ё', 'е'),
            '[^[:alnum:]]+',
            ''
        ) as sphere_korpus,
        regexp_replace(
            replace(lower(trim(s.stroenie_raw)), 'ё', 'е'),
            '[^[:alnum:]]+',
            ''
        ) as sphere_stroenie,
        s.unit_type_raw as sphere_unit_type,
        regexp_replace(
            replace(lower(trim(s.unit_raw)), 'ё', 'е'),
            '[^[:alnum:]]+',
            ''
        ) as sphere_unit
    from sphere_parts_raw s
),

sphere_core_keys as (
    /* Короткий список адресов ограничивает поиск по большой таблице ЕГРН. */
    select distinct
        sphere_locality,
        sphere_street,
        sphere_house
    from sphere_prepared
    where sphere_locality is not null
      and sphere_street is not null
      and sphere_house is not null
),

egrn_normalized as (
    /* Готовим адрес и минимальный набор данных ЕГРН. */
    select /*+ materialize */
        coalesce(
            nullif(trim(e.cadaster), ''),
            'CAD_IND:' || to_char(e.cad_ind)
        ) as egrn_key,
        e.cad_ind,
        e.cadaster,
        e.egrn_address,
        e.square,
        e.measure,
        e.building_type,
        e.oks_type,
        e.oks_purpose,
        e.object_status,
        e.fias_id_house,
        e.fias_id_flat,
        e.row_update_date,
        e.ias_update_date,
        regexp_replace(trim(e.postal_code), '[^0-9]+', '')
            as egrn_postal_code,
        regexp_replace(
            regexp_replace(
                replace(lower(trim(e.region)), 'ё', 'е'),
                '(^|[[:space:]])(область|обл|край|республика|респ)([.]|[[:space:]]|$)',
                ' '
            ),
            '[^[:alnum:]]+',
            ''
        ) as egrn_region,
        regexp_replace(
            regexp_replace(
                replace(lower(trim(e.city)), 'ё', 'е'),
                '(^|[[:space:]])(город|г)([.]|[[:space:]]|$)',
                ' '
            ),
            '[^[:alnum:]]+',
            ''
        ) as egrn_city,
        regexp_replace(
            regexp_replace(
                replace(lower(trim(e.settlement)), 'ё', 'е'),
                '(^|[[:space:]])(пгт|поселок городского типа|рабочий поселок|рп|поселок|пос|село|с|деревня|д)([.]|[[:space:]]|$)',
                ' '
            ),
            '[^[:alnum:]]+',
            ''
        ) as egrn_settlement,
        regexp_replace(
            regexp_replace(
                replace(lower(trim(e.street)), 'ё', 'е'),
                '(^|[[:space:]])(улица|ул|проспект|пр-кт|переулок|пер|шоссе|ш|набережная|наб|бульвар|б-р|проезд|площадь|пл|тракт|аллея)([.]|[[:space:]]|$)',
                ' '
            ),
            '[^[:alnum:]]+',
            ''
        ) as egrn_street,
        regexp_replace(
            replace(lower(trim(e.house_number)), 'ё', 'е'),
            '[^[:alnum:]]+',
            ''
        ) as egrn_house,
        regexp_replace(
            replace(lower(trim(e.vladenie)), 'ё', 'е'),
            '[^[:alnum:]]+',
            ''
        ) as egrn_vladenie,
        regexp_replace(
            replace(lower(trim(e.korpus)), 'ё', 'е'),
            '[^[:alnum:]]+',
            ''
        ) as egrn_korpus,
        regexp_replace(
            replace(lower(trim(e.stroenie)), 'ё', 'е'),
            '[^[:alnum:]]+',
            ''
        ) as egrn_stroenie,
        regexp_replace(replace(lower(trim(e.flat)), 'ё', 'е'), '[^[:alnum:]]+', '')
            as egrn_flat,
        regexp_replace(replace(lower(trim(e.flat2)), 'ё', 'е'), '[^[:alnum:]]+', '')
            as egrn_flat2,
        regexp_replace(replace(lower(trim(e.office)), 'ё', 'е'), '[^[:alnum:]]+', '')
            as egrn_office,
        regexp_replace(replace(lower(trim(e.office2)), 'ё', 'е'), '[^[:alnum:]]+', '')
            as egrn_office2,
        regexp_replace(replace(lower(trim(e.room)), 'ё', 'е'), '[^[:alnum:]]+', '')
            as egrn_room,
        regexp_replace(replace(lower(trim(e.room2)), 'ё', 'е'), '[^[:alnum:]]+', '')
            as egrn_room2,
        regexp_replace(replace(lower(trim(e.compartment1)), 'ё', 'е'), '[^[:alnum:]]+', '')
            as egrn_compartment1,
        regexp_replace(replace(lower(trim(e.compartment2)), 'ё', 'е'), '[^[:alnum:]]+', '')
            as egrn_compartment2
    from DM_RISK_AVATAR.EGRN_DATA e
    where e.cadaster is not null
       or e.cad_ind is not null
),

egrn_candidates as (
    /* Оставляем только адреса, которые могут относиться к нашей выгрузке. */
    select e.*
    from egrn_normalized e
    join sphere_core_keys k
        on k.sphere_street = e.egrn_street
       and k.sphere_house in (e.egrn_house, e.egrn_vladenie)
       and k.sphere_locality in (e.egrn_city, e.egrn_settlement)
),

address_matches as (
    /* Корпус, строение и помещение проверяются, если указаны в Сфере. */
    select
        s.sphere_row_id,
        e.*
    from sphere_prepared s
    join egrn_candidates e
       on s.sphere_street = e.egrn_street
       and s.sphere_house in (e.egrn_house, e.egrn_vladenie)
       and s.sphere_locality in (e.egrn_city, e.egrn_settlement)
       and (
           s.sphere_region is null
           or e.egrn_region is null
           or s.sphere_region = e.egrn_region
       )
       and (
           s.sphere_postal_code is null
           or e.egrn_postal_code is null
           or s.sphere_postal_code = e.egrn_postal_code
       )
       and (
           s.sphere_korpus is null
           or s.sphere_korpus = e.egrn_korpus
       )
       and (
           s.sphere_stroenie is null
           or s.sphere_stroenie = e.egrn_stroenie
       )
       and (
           (
               s.sphere_unit is null
               and e.egrn_flat is null
               and e.egrn_flat2 is null
               and e.egrn_office is null
               and e.egrn_office2 is null
               and e.egrn_room is null
               and e.egrn_room2 is null
               and e.egrn_compartment1 is null
               and e.egrn_compartment2 is null
           )
           or (
               s.sphere_unit_type = 'Квартира'
               and s.sphere_unit in (e.egrn_flat, e.egrn_flat2)
           )
           or (
               s.sphere_unit_type = 'Офис'
               and s.sphere_unit in (e.egrn_office, e.egrn_office2)
           )
           or (
               s.sphere_unit_type = 'Комната'
               and s.sphere_unit in (e.egrn_room, e.egrn_room2)
           )
           or (
               s.sphere_unit_type = 'Помещение'
               and s.sphere_unit in (
                   e.egrn_compartment1,
                   e.egrn_compartment2
               )
           )
       )
    where s.sphere_locality is not null
      and s.sphere_street is not null
      and s.sphere_house is not null
),

ranked_egrn_rows as (
    /* Один кадастровый объект может повторяться. Оставляем свежую запись. */
    select
        m.*,
        row_number() over (
            partition by m.sphere_row_id, m.egrn_key
            order by
                m.row_update_date desc nulls last,
                m.ias_update_date desc nulls last,
                m.cad_ind desc nulls last
        ) as egrn_row_number
    from address_matches m
),

one_row_per_egrn_object as (
    select r.*
    from ranked_egrn_rows r
    where r.egrn_row_number = 1
),

candidate_counts as (
    select
        c.*,
        count(*) over (
            partition by c.sphere_row_id
        ) as candidate_count
    from one_row_per_egrn_object c
),

candidate_summary as (
    select
        c.sphere_row_id,
        max(c.candidate_count) as candidate_count
    from candidate_counts c
    group by c.sphere_row_id
),

chosen_egrn as (
    /* ЕГРН присоединяется только при одном кандидате. */
    select c.*
    from candidate_counts c
    where c.candidate_count = 1
)

select
    /* Договор и основные ID строки Сферы. */
    sphere.contract_number as "Номер договора",
    sphere.contract_id as "ID договора",
    sphere.task_id as "ID задачи",
    sphere.task_object_link_id as "ID связи задачи и объекта",
    sphere.characteristics_id as "ID характеристик",
    sphere.object_id as "ID объекта Сферы",
    sphere.geo_address_id as "ID адреса Сферы",
    sphere.real_estate_objects_in_contract
        as "Объектов недвижимости в договоре",

    /* Объект и исходные адресные строки. */
    sphere.object_description as "Описание объекта Сферы",
    sphere.full_address as "Полный адрес Сферы",
    sphere.original_address as "Исходный адрес Сферы",
    prepared.source_address as "Адрес, который разбирал запрос",
    sphere.total_area as "Площадь Сферы",

    /* Части адреса, которые уже лежали в отдельных колонках Сферы. */
    sphere.postal_code as "Сфера: почтовый индекс",
    sphere.settlement as "Сфера: населённый пункт",
    sphere.street as "Сфера: улица",
    sphere.house as "Сфера: дом",
    sphere.block as "Сфера: корпус",
    sphere.building as "Сфера: строение",
    sphere.flat as "Сфера: квартира или помещение",
    sphere.office as "Сфера: офис",

    /* Так запрос разбил исходную строку адреса до очистки. */
    prepared.postal_code_raw as "После разбора: почтовый индекс",
    prepared.region_raw as "После разбора: регион",
    prepared.locality_raw as "После разбора: населённый пункт",
    prepared.street_raw as "После разбора: улица",
    prepared.house_raw as "После разбора: дом",
    prepared.korpus_raw as "После разбора: корпус",
    prepared.stroenie_raw as "После разбора: строение",
    prepared.unit_type_raw as "После разбора: вид помещения",
    prepared.unit_raw as "После разбора: номер помещения",

    /* Итог поиска. */
    case
        when prepared.source_address is null
            then 'В Сфере нет адреса'
        when prepared.sphere_locality is null
          or prepared.sphere_street is null
          or prepared.sphere_house is null
            then 'Не удалось выделить населённый пункт, улицу или дом'
        when nvl(summary.candidate_count, 0) = 0
            then 'В ЕГРН ничего не найдено'
        when summary.candidate_count = 1
            then 'Найден один объект ЕГРН'
        else 'Найдено несколько объектов. ЕГРН не присоединён'
    end as "Результат поиска",
    nvl(summary.candidate_count, 0) as "Кандидатов ЕГРН",

    /* Эти очищенные значения непосредственно сравниваются с ЕГРН. */
    prepared.sphere_postal_code as "Ключ поиска: почтовый индекс",
    prepared.sphere_region as "Ключ поиска: регион",
    prepared.sphere_locality as "Ключ поиска: населённый пункт",
    prepared.sphere_street as "Ключ поиска: улица",
    prepared.sphere_house as "Ключ поиска: дом",
    prepared.sphere_korpus as "Ключ поиска: корпус",
    prepared.sphere_stroenie as "Ключ поиска: строение",
    prepared.sphere_unit_type as "Ключ поиска: вид помещения",
    prepared.sphere_unit as "Ключ поиска: номер помещения",

    /* Поля ЕГРН заполняются только для однозначной связи. */
    chosen.cad_ind as "Внутренний ID ЕГРН",
    chosen.cadaster as "Кадастровый номер",
    chosen.egrn_address as "Адрес ЕГРН",
    chosen.square as "Площадь ЕГРН",
    chosen.measure as "Единица площади ЕГРН",
    chosen.building_type as "Тип строения ЕГРН",
    chosen.oks_type as "Тип объекта ЕГРН",
    chosen.oks_purpose as "Назначение объекта ЕГРН",
    chosen.object_status as "Статус объекта ЕГРН",
    chosen.fias_id_house as "ФИАС дома ЕГРН",
    chosen.fias_id_flat as "ФИАС помещения ЕГРН"

from sphere_source sphere
join sphere_prepared prepared
    on prepared.sphere_row_id = sphere.sphere_row_id
left join candidate_summary summary
    on summary.sphere_row_id = sphere.sphere_row_id
left join chosen_egrn chosen
    on chosen.sphere_row_id = sphere.sphere_row_id
order by
    sphere.contract_number,
    sphere.object_id;

/*
Как читать результат
--------------------
Найден один объект ЕГРН
    Связь однозначная. Поля ЕГРН заполнены.

Найдено несколько объектов
    По адресу есть несколько кадастровых объектов. Ничего не присоединено.
    Следующим шагом такие строки можно проверять с помощью площади.

В ЕГРН ничего не найдено
    Адрес удалось разобрать, но подходящего адреса в ЕГРН не найдено.

Не удалось выделить населённый пункт, улицу или дом
    Адрес есть, но его недостаточно для безопасного автоматического поиска.
*/
