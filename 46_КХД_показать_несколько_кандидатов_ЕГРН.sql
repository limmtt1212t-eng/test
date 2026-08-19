/*
Проверка случаев, когда по одному объекту Сферы найдено несколько зданий ЕГРН.

Запускать в Oracle целиком.

Одна строка результата — один кандидат ЕГРН.
Один объект Сферы поэтому может занимать несколько строк.
Запрос ничего не присоединяет к датасету, а только показывает варианты для проверки.
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
                '(^|,)[[:space:]]*(пгт|поселок городского типа|рабочий поселок|рп|поселок|пос|село|с|деревня|д|хутор|х)[.]?[[:space:]]+([^,]+)',
                1, 1, 'i', 3
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*([^,]+)[[:space:]]*,[[:space:]]*([^,]*(улица|ул[.]?|проспект|пр-кт|переулок|пер[.]?|шоссе|ш[.]?|набережная|наб[.]?|бульвар|б-р|проезд|площадь|пл[.]?|тракт|аллея))([[:space:]]*,|$)',
                1, 1, 'i', 2
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
                '(^|,)[[:space:]]*(корпус|корп|к)([.]|[[:space:]])+[[:space:]]*([0-9а-яa-z/-]+)',
                1, 1, 'i', 4
            )
        ) as korpus_raw,
        coalesce(
            nullif(trim(s.building), ''),
            regexp_substr(
                s.address_text,
                '(^|,|[[:space:]])(строение|стр)[.]?[[:space:]]*([0-9а-яa-z/-]+)',
                1, 1, 'i', 3
            )
        ) as stroenie_raw
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
                '(^|[[:space:]])(город|г|пгт|поселок городского типа|рабочий поселок|рп|поселок|пос|село|с|деревня|д|хутор|х)([.]|[[:space:]]|$)',
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
        ) as sphere_stroenie
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
        e.fias_level,
        e.fias_id_house,
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
                '(^|[[:space:]])(пгт|поселок городского типа|рабочий поселок|рп|поселок|пос|село|с|деревня|д|хутор|х)([.]|[[:space:]]|$)',
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
        ) as egrn_stroenie
    from DM_RISK_AVATAR.EGRN_DATA e
    where upper(trim(e.fias_level)) = 'FIAS_HOUSE'
      and lower(trim(e.oks_type)) in (
          'здание',
          'сооружение',
          'строение'
      )
      and e.flat is null
      and e.flat2 is null
      and e.office is null
      and e.office2 is null
      and e.room is null
      and e.room2 is null
      and e.compartment1 is null
      and e.compartment2 is null
      and (
          e.cadaster is not null
          or e.cad_ind is not null
      )
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
    /* Сравниваем адрес только до уровня здания. */
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

)
select
    /* Объект Сферы, для которого найдено несколько вариантов. */
    sphere.contract_number as "Номер договора",
    sphere.contract_id as "ID договора",
    sphere.task_id as "ID задачи",
    sphere.task_object_link_id as "ID связи задачи и объекта",
    sphere.characteristics_id as "ID характеристик",
    sphere.object_id as "ID объекта Сферы",
    sphere.geo_address_id as "ID адреса Сферы",
    sphere.object_description as "Описание объекта Сферы",
    sphere.total_area as "Площадь объекта Сферы",
    sphere.full_address as "Полный адрес Сферы",
    sphere.original_address as "Исходный адрес Сферы",
    sphere.flat as "Квартира или помещение Сферы",
    sphere.office as "Офис Сферы",

    /* Сколько зданий ЕГРН подошло и какой кандидат показан в этой строке. */
    candidate.candidate_count as "Всего кандидатов ЕГРН",
    row_number() over (
        partition by sphere.sphere_row_id
        order by candidate.cadaster, candidate.cad_ind
    ) as "Номер кандидата",

    /* Части адреса показаны парами, чтобы сразу увидеть сравнение. */
    prepared.sphere_postal_code as "Индекс Сферы",
    candidate.egrn_postal_code as "Индекс ЕГРН",

    prepared.sphere_region as "Регион Сферы",
    candidate.egrn_region as "Регион ЕГРН",

    prepared.sphere_locality as "Населённый пункт Сферы",
    case
        when prepared.sphere_locality = candidate.egrn_city
            then candidate.egrn_city
        when prepared.sphere_locality = candidate.egrn_settlement
            then candidate.egrn_settlement
        else coalesce(candidate.egrn_city, candidate.egrn_settlement)
    end as "Населённый пункт ЕГРН",

    prepared.sphere_street as "Улица Сферы",
    candidate.egrn_street as "Улица ЕГРН",

    prepared.sphere_house as "Дом Сферы",
    case
        when prepared.sphere_house = candidate.egrn_house
            then candidate.egrn_house
        when prepared.sphere_house = candidate.egrn_vladenie
            then candidate.egrn_vladenie
        else coalesce(candidate.egrn_house, candidate.egrn_vladenie)
    end as "Дом ЕГРН",

    prepared.sphere_korpus as "Корпус Сферы",
    candidate.egrn_korpus as "Корпус ЕГРН",
    prepared.sphere_stroenie as "Строение Сферы",
    candidate.egrn_stroenie as "Строение ЕГРН",

    /* Поля, по которым можно оценить кандидатов. */
    candidate.cad_ind as "Внутренний ID ЕГРН",
    candidate.cadaster as "Кадастровый номер",
    candidate.egrn_address as "Полный адрес ЕГРН",
    candidate.fias_id_house as "ФИАС дома",
    candidate.fias_level as "Уровень адреса",
    candidate.square as "Площадь ЕГРН",
    candidate.measure as "Единица площади",
    candidate.building_type as "Тип строения",
    candidate.oks_type as "Тип объекта ЕГРН",
    candidate.oks_purpose as "Назначение объекта ЕГРН",
    candidate.object_status as "Статус объекта ЕГРН",
    candidate.row_update_date as "Дата обновления записи",
    candidate.ias_update_date as "Дата обновления ИАС"

from sphere_source sphere
join sphere_prepared prepared
    on prepared.sphere_row_id = sphere.sphere_row_id
join candidate_counts candidate
    on candidate.sphere_row_id = sphere.sphere_row_id
where candidate.candidate_count >= 2
order by
    sphere.contract_number,
    sphere.object_id,
    "Номер кандидата";
