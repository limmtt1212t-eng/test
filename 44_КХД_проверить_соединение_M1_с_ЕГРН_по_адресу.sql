/*
Проверка соединения датасета модели 1 с ЕГРН по адресу.

Запускать в Oracle.

Результат содержит одну строку на объект Сферы. Данные ЕГРН заполняются
только тогда, когда по адресу найдена одна запись уровня здания.

Для поиска используются населённый пункт, улица и дом. Корпус и строение
учитываются, если они указаны.
Индекс и регион сравниваются, если они заполнены с обеих сторон.
Если по адресу найдено несколько зданий, площадь используется как
дополнительная проверка. Если площади нет или она не помогла, кандидаты
по адресу не отсекаются.

В поиск попадают только типы ЕГРН «здание», «сооружение» и «строение»
с уровнем адреса FIAS_HOUSE. Квартиры, офисы, комнаты и помещения исключены.
Если по одному адресу Сферы записано несколько страховых объектов,
одно найденное здание ЕГРН присоединяется к каждому из них.

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
        replace(
            regexp_replace(trim(s.total_area), '[[:space:]]+', ''),
            ',',
            '.'
        ) as sphere_area_text,
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
                '^[[:space:]]*([^,(]+)[[:space:]]*[(]',
                1, 1, 'i', 1
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(город|г)[.]?[[:space:]]+([^,]+)',
                1, 1, 'i', 3
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(пгт|поселок городского типа|рабочий поселок|р[.]?п|поселок|пос|село|с|деревня|д|хутор|х)[.]?[[:space:]]+([^,]+)',
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
        case
            when regexp_like(
                s.sphere_area_text,
                '^[0-9]+([.][0-9]+)?$'
            )
            then to_number(
                s.sphere_area_text,
                '999999999999999999999999D9999999999',
                'NLS_NUMERIC_CHARACTERS=''.,'''
            )
        end as sphere_area,
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
                '(^|[[:space:]])(город|г|пгт|поселок городского типа|рабочий поселок|р[.]?п|поселок|пос|село|с|деревня|д|хутор|х)([.]|[[:space:]]|$)',
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
                '(^|[[:space:]])(пгт|поселок городского типа|рабочий поселок|р[.]?п|поселок|пос|село|с|деревня|д|хутор|х)([.]|[[:space:]]|$)',
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
        s.sphere_area,
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

area_check as (
    /* Площадь проверяем только там, где она есть с обеих сторон. */
    select
        c.*,
        count(*) over (
            partition by c.sphere_row_id
        ) as address_candidate_count,
        case
            when c.sphere_area > 0
             and c.square is not null
             and abs(c.square - c.sphere_area)
                 <= greatest(1, c.sphere_area * 0.01)
                then 1
            else 0
        end as area_matches
    from one_row_per_egrn_object c
),

area_choice as (
    select
        a.*,
        max(a.area_matches) over (
            partition by a.sphere_row_id
        ) as has_area_match
    from area_check a
),

candidates_after_area as (
    /* Если площадь помогла, оставляем совпавших. Иначе никого не отсекаем. */
    select a.*
    from area_choice a
    where a.has_area_match = 0
       or a.area_matches = 1
),

candidate_counts as (
    select
        c.*,
        count(*) over (
            partition by c.sphere_row_id
        ) as candidate_count
    from candidates_after_area c
),

candidate_summary as (
    select
        c.sphere_row_id,
        max(c.candidate_count) as candidate_count,
        max(c.address_candidate_count) as address_candidate_count,
        max(c.has_area_match) as has_area_match
    from candidate_counts c
    group by c.sphere_row_id
),

chosen_egrn as (
    /* Здание ЕГРН присоединяется только при одном кандидате. */
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

    /* Итог поиска. */
    case
        when prepared.source_address is null
            then 'В Сфере нет адреса'
        when prepared.sphere_locality is null
          or prepared.sphere_street is null
          or prepared.sphere_house is null
            then 'Не удалось выделить населённый пункт, улицу или дом'
        when nvl(summary.candidate_count, 0) = 0
            then 'Здание ЕГРН не найдено'
        when summary.candidate_count = 1
            then 'Найдено одно здание ЕГРН'
        else 'Найдено несколько зданий. ЕГРН не присоединён'
    end as "Результат поиска",
    nvl(summary.address_candidate_count, 0)
        as "Кандидатов по адресу",
    nvl(summary.candidate_count, 0)
        as "Кандидатов после площади",
    case
        when summary.address_candidate_count > summary.candidate_count
            then 'Да'
        else 'Нет'
    end as "Площадь помогла сузить поиск",

    /* Очищенные значения показаны парами: Сфера и найденное здание КХД. */
    prepared.sphere_postal_code as "Сравнение: индекс Сферы",
    chosen.egrn_postal_code as "Сравнение: индекс КХД",

    prepared.sphere_region as "Сравнение: регион Сферы",
    chosen.egrn_region as "Сравнение: регион КХД",

    prepared.sphere_locality as "Сравнение: населённый пункт Сферы",
    case
        when prepared.sphere_locality = chosen.egrn_city
            then chosen.egrn_city
        when prepared.sphere_locality = chosen.egrn_settlement
            then chosen.egrn_settlement
    end as "Сравнение: населённый пункт КХД",

    prepared.sphere_street as "Сравнение: улица Сферы",
    chosen.egrn_street as "Сравнение: улица КХД",

    prepared.sphere_house as "Сравнение: дом Сферы",
    case
        when prepared.sphere_house = chosen.egrn_house
            then chosen.egrn_house
        when prepared.sphere_house = chosen.egrn_vladenie
            then chosen.egrn_vladenie
    end as "Сравнение: дом КХД",

    prepared.sphere_korpus as "Сравнение: корпус Сферы",
    chosen.egrn_korpus as "Сравнение: корпус КХД",

    prepared.sphere_stroenie as "Сравнение: строение Сферы",
    chosen.egrn_stroenie as "Сравнение: строение КХД",

    /* Поля одного найденного здания. */
    chosen.cad_ind as "Внутренний ID здания ЕГРН",
    chosen.cadaster as "Кадастровый номер здания",
    chosen.egrn_address as "Адрес здания ЕГРН",
    chosen.square as "Площадь здания ЕГРН",
    chosen.measure as "Единица площади здания",
    chosen.building_type as "Тип строения здания ЕГРН",
    chosen.oks_type as "Тип здания ЕГРН",
    chosen.oks_purpose as "Назначение здания ЕГРН",
    chosen.object_status as "Статус здания ЕГРН",
    chosen.fias_level as "Уровень адреса ЕГРН",
    chosen.fias_id_house as "ФИАС дома ЕГРН",
    case
        when chosen.cad_ind is not null then 'Здание'
    end as "Уровень присоединения"

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
Найдено одно здание ЕГРН
    Здание присоединено ко всем объектам Сферы с этим адресом.

Найдено несколько зданий
    По адресу есть несколько кадастровых зданий. Ничего не присоединено.

Здание ЕГРН не найдено
    Адрес удалось разобрать, но запись уровня FIAS_HOUSE не найдена.

Не удалось выделить населённый пункт, улицу или дом
    Адрес есть, но его недостаточно для безопасного автоматического поиска.
*/
