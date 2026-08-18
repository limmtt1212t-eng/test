/*
Запускать в Oracle.

Что делает запрос
-----------------
Берёт объекты из уже загруженной таблицы SVETOVAVS.SPHERE_OBJECTS.
Разбирает полный адрес на части.
Сравнивает эти части с адресом в DM_RISK_AVATAR.EGRN_DATA.

Для поиска используются:
- населённый пункт;
- улица;
- дом;
- регион и индекс, если они есть с обеих сторон;
- корпус и строение, если они указаны в Сфере;
- вид и номер квартиры, офиса, комнаты или помещения.

Площадь в этом запросе не используется.

Если найден один кадастровый объект, данные ЕГРН присоединяются.
Если найдено несколько объектов, данные ЕГРН не присоединяются.
Исходные строки Сферы не удаляются и не размножаются.
*/

with sphere_text as (
    /* Берём полный адрес из загруженной таблицы. */
    select /*+ materialize */
        rowidtochar(s.rowid) as sphere_row_id,
        cast(s."Полный адрес" as varchar2(4000)) as sphere_full_address,
        regexp_replace(
            regexp_replace(
                replace(
                    lower(
                        replace(
                            trim(cast(s."Полный адрес" as varchar2(4000))),
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
    from SVETOVAVS.SPHERE_OBJECTS s
),

sphere_parts_raw as (
    /* Здесь из адреса выделяются его отдельные части. */
    select
        s.*,

        regexp_substr(
            s.address_text,
            '(^|,)[[:space:]]*([0-9]{6})([[:space:]]*,|$)',
            1, 1, 'i', 2
        ) as postal_code_raw,

        regexp_substr(
            s.address_text,
            '(^|,)[[:space:]]*([^,]*(область|обл[.]?|край|республика|респ[.]?)[^,]*)',
            1, 1, 'i', 2
        ) as region_raw,

        regexp_substr(
            s.address_text,
            '(^|,)[[:space:]]*([^,]*(район|р-н)[^,]*)',
            1, 1, 'i', 2
        ) as rayon_raw,

        coalesce(
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(город|г)[.]?[[:space:]]+([^,]+)',
                1, 1, 'i', 3
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(пгт|поселок городского типа|рабочий поселок|рп|поселок|пос|село|с|деревня|д)[.]?[[:space:]]+([^,]+)',
                1, 1, 'i', 3
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*([^,]+)[[:space:]]*,[[:space:]]*[^,]*(улица|ул[.]?|проспект|пр-кт|переулок|пер[.]?|шоссе|ш[.]?|набережная|наб[.]?|бульвар|б-р|проезд|площадь|пл[.]?|тракт|аллея)([[:space:]]|,|$)',
                1, 1, 'i', 2
            )
        ) as locality_raw,

        coalesce(
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
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*(дом|д)[.]?[[:space:]]*([0-9]+[а-яa-z]?([/-][0-9а-яa-z]+)?)',
                1, 1, 'i', 3
            ),
            regexp_substr(
                s.address_text,
                '(улица|ул[.]?|проспект|пр-кт|переулок|пер[.]?|шоссе|ш[.]?|набережная|наб[.]?|бульвар|б-р|проезд|площадь|пл[.]?|тракт|аллея)[^,]*,[[:space:]]*([0-9]+[а-яa-z]?([/-][0-9а-яa-z]+)?)',
                1, 1, 'i', 2
            ),
            regexp_substr(
                s.address_text,
                '(^|,)[[:space:]]*([0-9]{1,5}[а-яa-z]?([/-][0-9а-яa-z]+)?)([[:space:]]*,|$)',
                1, 1, 'i', 2
            )
        ) as house_raw,

        regexp_substr(
            s.address_text,
            '(^|,)[[:space:]]*(корпус|корп|к)[.]?[[:space:]]*([0-9а-яa-z/-]+)',
            1, 1, 'i', 3
        ) as korpus_raw,

        regexp_substr(
            s.address_text,
            '(^|,)[[:space:]]*(строение|стр)[.]?[[:space:]]*([0-9а-яa-z/-]+)',
            1, 1, 'i', 3
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
            )
        ) as unit_raw
    from sphere_text s
),

sphere_prepared as (
    /* Для сравнения убираем регистр, пробелы и знаки препинания. */
    select /*+ materialize */
        s.sphere_row_id,
        s.sphere_full_address,
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
                replace(lower(trim(s.rayon_raw)), 'ё', 'е'),
                '(^|[[:space:]])(район|р-н)([.]|[[:space:]]|$)',
                ' '
            ),
            '[^[:alnum:]]+',
            ''
        ) as sphere_rayon,
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
    /* Этот короткий список ограничивает поиск в большой таблице ЕГРН. */
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
    /* Готовим адресные части ЕГРН в таком же виде. */
    select
        coalesce(
            nullif(trim(e.cadaster), ''),
            'CAD_IND:' || to_char(e.cad_ind)
        ) as egrn_key,
        e.cad_ind,
        e.cadaster,
        e.egrn_address,
        e.square,
        e.measure,
        e.price,
        e.square_meter_price,
        e.building_type,
        e.building_object_type,
        e.oks_type_full,
        e.oks_type,
        e.oks_purpose,
        e.object_status,
        e.comissioning_year,
        e.construction_complete_year,
        e.floor_capacity_map,
        e.wall_material_short,
        e.fias_id,
        e.fias_id_house,
        e.fias_id_flat,
        e.geo_latitude,
        e.geo_longitude,
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
                replace(lower(trim(e.rayon)), 'ё', 'е'),
                '(^|[[:space:]])(район|р-н)([.]|[[:space:]]|$)',
                ' '
            ),
            '[^[:alnum:]]+',
            ''
        ) as egrn_rayon,
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
    /* Здесь применяются все правила сравнения адреса. */
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
           s.sphere_rayon is null
           or e.egrn_rayon is null
           or s.sphere_rayon = e.egrn_rayon
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

ranked_source_rows as (
    /* В ЕГРН бывают повторы одного объекта. Оставляем свежую запись. */
    select
        m.*,
        row_number() over (
            partition by m.sphere_row_id, m.egrn_key
            order by
                m.row_update_date desc nulls last,
                m.ias_update_date desc nulls last,
                m.cad_ind desc nulls last
        ) as source_row_number
    from address_matches m
),

one_row_per_egrn_object as (
    select r.*
    from ranked_source_rows r
    where r.source_row_number = 1
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
    /* Присоединяем ЕГРН только при одном кандидате. */
    select c.*
    from candidate_counts c
    where c.candidate_count = 1
)

select
    sphere.*,

    case
        when prepared.sphere_full_address is null
            then 'В Сфере нет полного адреса'
        when prepared.sphere_locality is null
          or prepared.sphere_street is null
          or prepared.sphere_house is null
            then 'Не удалось выделить город, улицу или дом'
        when nvl(summary.candidate_count, 0) = 0
            then 'В ЕГРН ничего не найдено'
        when summary.candidate_count = 1
            then 'Найден один объект ЕГРН'
        else 'Найдено несколько объектов. ЕГРН не присоединён'
    end as "Результат поиска в ЕГРН",

    nvl(summary.candidate_count, 0) as "Количество кандидатов ЕГРН",
    prepared.sphere_locality as "Населенный пункт для поиска",
    prepared.sphere_street as "Улица для поиска",
    prepared.sphere_house as "Дом для поиска",
    prepared.sphere_korpus as "Корпус для поиска",
    prepared.sphere_stroenie as "Строение для поиска",
    prepared.sphere_unit_type as "Вид помещения для поиска",
    prepared.sphere_unit as "Номер помещения для поиска",

    chosen.cad_ind as "Внутренний ID ЕГРН",
    chosen.cadaster as "Кадастровый номер",
    chosen.egrn_address as "Адрес ЕГРН",
    chosen.square as "Площадь ЕГРН",
    chosen.measure as "Единица площади ЕГРН",
    chosen.price as "Кадастровая стоимость",
    chosen.square_meter_price as "Кадастровая стоимость кв. м",
    chosen.building_type as "Тип строения ЕГРН",
    chosen.building_object_type as "Тип объекта в строении ЕГРН",
    chosen.oks_type_full as "Полный тип и назначение ЕГРН",
    chosen.oks_type as "Тип объекта ЕГРН",
    chosen.oks_purpose as "Назначение объекта ЕГРН",
    chosen.object_status as "Статус объекта ЕГРН",
    chosen.comissioning_year as "Год ввода в эксплуатацию",
    chosen.construction_complete_year as "Год завершения строительства",
    chosen.floor_capacity_map as "Этажность ЕГРН",
    chosen.wall_material_short as "Материал стен ЕГРН",
    chosen.fias_id as "ФИАС ЕГРН",
    chosen.fias_id_house as "ФИАС дома ЕГРН",
    chosen.fias_id_flat as "ФИАС помещения ЕГРН",
    chosen.geo_latitude as "Широта ЕГРН",
    chosen.geo_longitude as "Долгота ЕГРН"

from SVETOVAVS.SPHERE_OBJECTS sphere
join sphere_prepared prepared
    on prepared.sphere_row_id = rowidtochar(sphere.rowid)
left join candidate_summary summary
    on summary.sphere_row_id = prepared.sphere_row_id
left join chosen_egrn chosen
    on chosen.sphere_row_id = prepared.sphere_row_id
order by rowidtochar(sphere.rowid);

/*
Как читать результат
--------------------
"Найден один объект ЕГРН" означает связь один к одному.
Только в этих строках заполнены данные ЕГРН.

"Найдено несколько объектов" означает неоднозначную связь.
В этих строках данные ЕГРН оставлены пустыми.

"В ЕГРН ничего не найдено" означает, что адрес не дал совпадения.
Исходная строка Сферы при этом остаётся в результате.

Важно
-----
Это аналитическое сопоставление, а не подтверждение права собственности.
Запрос только показывает результат. Он не создаёт и не меняет таблицы.
*/
