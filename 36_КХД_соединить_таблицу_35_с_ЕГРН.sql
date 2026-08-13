/*
Запускать в Oracle после загрузки результата запроса №35.

Перед запуском
--------------
1. Загруженная таблица: SVETOVAVS.SPHERE_OBJECTS.
2. При загрузке сохранить заголовки из результата запроса №35.
3. Таблица EGRN_DATA находится в схеме DM_RISK_AVATAR.

Правило соединения
------------------
1. Сначала ищем кандидатов ЕГРН по полному адресу объекта Сферы.
   Регистр, пробелы и знаки препинания при сравнении не учитываются.
2. Если по адресу найден ровно один кадастровый объект — присоединяем его.
3. Если по адресу найдено несколько объектов, ни один из них не выбираем.
4. Если адрес не найден или найдено несколько кандидатов, строку Сферы
   сохраняем, а поля ЕГРН оставляем NULL.

Важно
-----
- Адрес используется как средство поиска, а не как ID объекта.
- Колонка площади не была загружена, поэтому в этой версии она не используется.
- Запрос не выбирает случайного кандидата.
*/

with sphere_source as (
    /* Это загруженная из CSV таблица Сферы. */
    select
        rowidtochar(source_row.rowid) as sphere_row_id_internal,
        source_row.*
    from SVETOVAVS.SPHERE_OBJECTS source_row
),

sphere_prepared as (
    select /*+ materialize */
        s.sphere_row_id_internal as sphere_row_id,
        s."Полный адрес" as sphere_address,
        regexp_replace(
            replace(
                lower(replace(trim(s."Полный адрес"), chr(160), ' ')),
                'ё',
                'е'
            ),
            '[^[:alnum:]]+',
            ''
        ) as sphere_address_key
    from sphere_source s
),

sphere_address_keys as (
    select distinct
        sphere_address_key
    from sphere_prepared
    where nullif(sphere_address_key, '') is not null
),

egrn_prepared as (
    select /*+ materialize */
        coalesce(
            nullif(trim(e.cadaster), ''),
            'CAD_IND:' || to_char(e.cad_ind)
        ) as egrn_key,
        regexp_replace(
            replace(
                lower(replace(trim(e.egrn_address), chr(160), ' ')),
                'ё',
                'е'
            ),
            '[^[:alnum:]]+',
            ''
        ) as egrn_address_key,
        e.cad_ind,
        e.cadaster,
        e.egrn_address,
        e.square,
        e.measure,
        e.price,
        e.square_meter_price,
        e.building_type,
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
        e.ias_update_date
    from dm_risk_avatar.egrn_data e
    join sphere_address_keys sphere_key
        on sphere_key.sphere_address_key = regexp_replace(
            replace(
                lower(replace(trim(e.egrn_address), chr(160), ' ')),
                'ё',
                'е'
            ),
            '[^[:alnum:]]+',
            ''
        )
    where nullif(trim(e.egrn_address), '') is not null
      and (e.cadaster is not null or e.cad_ind is not null)
),

egrn_ranked as (
    select
        e.*,
        row_number() over (
            partition by e.egrn_address_key, e.egrn_key
            order by
                e.row_update_date desc nulls last,
                e.ias_update_date desc nulls last,
                e.cad_ind desc nulls last
        ) as source_row_number
    from egrn_prepared e
),

egrn_one_row_per_object as (
    select
        egrn_key,
        egrn_address_key,
        cad_ind,
        cadaster,
        egrn_address,
        square,
        measure,
        price,
        square_meter_price,
        building_type,
        oks_type,
        oks_purpose,
        object_status,
        comissioning_year,
        construction_complete_year,
        floor_capacity_map,
        wall_material_short,
        fias_id,
        fias_id_house,
        fias_id_flat,
        geo_latitude,
        geo_longitude
    from egrn_ranked
    where source_row_number = 1
),

address_matches as (
    select
        sphere.sphere_row_id,
        sphere.sphere_address,
        egrn.*
    from sphere_prepared sphere
    join egrn_one_row_per_object egrn
        on egrn.egrn_address_key = sphere.sphere_address_key
    where nullif(sphere.sphere_address_key, '') is not null
),

candidate_counts as (
    select
        matches.*,
        count(*) over (
            partition by matches.sphere_row_id
        ) as address_candidate_count
    from address_matches matches
),

candidate_summary as (
    select
        sphere_row_id,
        max(address_candidate_count) as address_candidate_count
    from candidate_counts
    group by sphere_row_id
),

chosen_egrn as (
    select
        candidate.*
    from candidate_counts candidate
    where candidate.address_candidate_count = 1
)

select
    sphere.*,
    case
        when nullif(trim(sphere."Полный адрес"), '') is null
            then 'Нет полного адреса Сферы'
        when nvl(summary.address_candidate_count, 0) = 0
            then 'По адресу не найдено'
        when summary.address_candidate_count = 1
            then 'Найден один объект по адресу'
        else 'По адресу найдено несколько — ЕГРН не присоединён'
    end as "Результат соединения с ЕГРН",
    nvl(summary.address_candidate_count, 0)
        as "Кандидатов ЕГРН по адресу",

    chosen.cad_ind as "Внутренний ID ЕГРН",
    chosen.cadaster as "Кадастровый номер",
    chosen.egrn_address as "Адрес ЕГРН",
    chosen.square as "Площадь ЕГРН",
    chosen.measure as "Единица площади ЕГРН",
    chosen.price as "Кадастровая стоимость",
    chosen.square_meter_price as "Кадастровая стоимость кв. м",
    chosen.building_type as "Тип строения ЕГРН",
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
from sphere_source sphere
join sphere_prepared prepared
    on prepared.sphere_row_id = sphere.sphere_row_id_internal
left join candidate_summary summary
    on summary.sphere_row_id = prepared.sphere_row_id
left join chosen_egrn chosen
    on chosen.sphere_row_id = prepared.sphere_row_id
order by
    sphere.sphere_row_id_internal;

/*
Как проверить результат
-----------------------
- «Найден один объект по адресу» — данные ЕГРН присоединены по адресу.
- Во всех остальных статусах поля ЕГРН должны быть пустыми.

Подводные камни
---------------
1. Разное написание одного адреса может не дать совпадение: «ул.» и «улица»,
   перестановка частей адреса и старое название улицы здесь не исправляются.
2. Если по адресу есть несколько разных кадастровых объектов, поля ЕГРН остаются
   пустыми: площади Сферы в загруженной таблице нет.
3. В EGRN_DATA могут быть повторные строки одного кадастрового объекта.
   Запрос оставляет одну наиболее свежую строку для одного кадастрового ключа.
*/
