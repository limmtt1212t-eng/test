/*
Запускать в DBeaver в подключении к «Сфере».

Запрос берёт 20 свежих объектов, у которых есть:
- адрес, разбираемый на населённый пункт, улицу и дом;
- числовая общая площадь в characteristics -> total_area_sq_m.

Результатом будет одна ячейка «Oracle запрос».
Её нужно целиком скопировать и выполнить в Oracle.

В Oracle сначала ищутся объекты ЕГРН по адресу, затем кандидаты сужаются
по площади. Итогом будут не количества, а примеры найденных связей:
- один объект «Сферы» — один кандидат ЕГРН;
- один объект «Сферы» — несколько кандидатов ЕГРН.

В результате показаны поля ЕГРН, которые потенциально можно добавить к
объекту «Сферы»: кадастровый номер, тип, назначение, площадь, стоимость,
год, этажность и материал стен.

Один кадастровый номер считается одним кандидатом, даже если в EGRN_DATA
для него оказалось несколько строк. Для одного объекта показывается не
больше 10 наиболее близких по площади кандидатов.

Рабочий допуск площади: не больше 1 кв. м или 1% от площади «Сферы».
Это исследовательское правило, а не утверждённая бизнес-связь.
*/

with task_candidates as (
select
    contract.id as contract_id,
    coalesce(
        task.d_conclusion_ins_contract::timestamp with time zone,
        contract.d_sign_contract,
        task.d_create
    ) as object_date,
    task.id as task_id,
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
    object_date,
    task_id
from task_candidates
where task_number = 1
),

object_candidates as (
select
    selected.contract_id,
    selected.object_date,
    insurance_object.id as object_id,
    coalesce(
        nullif(btrim(address.full_address), ''),
        nullif(btrim(insurance_object.original_address), '')
    ) as source_address,
    nullif(btrim(address.settlement), '') as sphere_settlement,
    nullif(btrim(address.street), '') as sphere_street,
    nullif(btrim(address.house), '') as sphere_house,
    nullif(btrim(address.building), '') as sphere_stroenie,
    nullif(btrim(address.block), '') as sphere_korpus,
    nullif(
        replace(
            regexp_replace(
                btrim(characteristics.characteristics ->> 'total_area_sq_m'),
                '[[:space:]]+',
                '',
                'g'
            ),
            ',',
            '.'
        ),
        ''
    ) as area_text,
    row_number() over (
        partition by selected.task_id, insurance_object.id
        order by
            task_object.d_change desc nulls last,
            task_object.d_create desc nulls last,
            characteristics.version_start_date desc nulls last,
            characteristics.version_number desc nulls last,
            task_object.id desc,
            characteristics.id desc
    ) as object_number
from selected_tasks selected
join bps_request_ins_task_insurance_object task_object
    on task_object.parent_id = selected.task_id
join base_insurance_object_characteristics characteristics
    on characteristics.id = task_object.characteristics_id
join base_insurance_object insurance_object
    on insurance_object.id = characteristics.insurance_object_id
left join base_geo_address address
    on address.id = insurance_object.geo_address_id
where insurance_object.elementary_obj_type = 'nedv_ul_and_ip'
  and insurance_object.d_delete is null
),

one_row_per_object as (
select
    object_candidates.*,
    case
        when area_text ~ '^[0-9]+([.][0-9]+)?$'
         and area_text::numeric > 0
            then area_text::numeric
        else null
    end as sphere_area
from object_candidates
where object_number = 1
  and source_address is not null
),

normalized as (
select
    one_row_per_object.*,
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
from one_row_per_object
where sphere_area is not null
),

parsed as (
select
    normalized.*,
    coalesce(
        (regexp_match(
            address_lower,
            '(?:^|, )(?:г|город) ([^,]+)(?:,|$)'
        ))[1],
        sphere_settlement,
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
        sphere_street,
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
        sphere_house,
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
        sphere_korpus,
        (regexp_match(
            address_lower,
            '(?:^|, )(?:корп|корпус|к) *([0-9а-яa-z/-]+)(?:,|$)'
        ))[1]
    ) as parsed_korpus,
    coalesce(
        sphere_stroenie,
        (regexp_match(
            address_lower,
            '(?:^|, )(?:стр|строение) *([0-9а-яa-z/-]+)(?:,|$)'
        ))[1]
    ) as parsed_stroenie
from normalized
),

prepared as (
select
    contract_id,
    object_date,
    object_id::text as object_id,
    sphere_area,
    nullif(btrim(replace(lower(parsed_locality), 'ё', 'е')), '')
        as parsed_locality,
    nullif(btrim(replace(lower(parsed_street), 'ё', 'е')), '')
        as parsed_street,
    nullif(
        replace(btrim(replace(lower(parsed_house), 'ё', 'е')), ' ', ''),
        ''
    ) as parsed_house,
    nullif(
        replace(btrim(replace(lower(parsed_korpus), 'ё', 'е')), ' ', ''),
        ''
    ) as parsed_korpus,
    nullif(
        replace(btrim(replace(lower(parsed_stroenie), 'ё', 'е')), ' ', ''),
        ''
    ) as parsed_stroenie
from parsed
where parsed_locality is not null
  and parsed_street is not null
  and parsed_house is not null
),

test_objects as (
select *
from prepared
order by
    object_date desc nulls last,
    contract_id desc,
    object_id
limit 20
),

oracle_rows as (
select
    row_number() over (
        order by object_date desc nulls last, contract_id desc, object_id
    ) as row_number,
    'select '
    || '''' || replace(object_id, '''', '''''') || ''' as sphere_object_id, '
    || sphere_area::text || ' as sphere_area, '
    || '''' || replace(parsed_locality, '''', '''''') || ''' as sphere_locality, '
    || '''' || replace(parsed_street, '''', '''''') || ''' as sphere_street, '
    || '''' || replace(parsed_house, '''', '''''') || ''' as sphere_house, '
    || case
        when parsed_korpus is null then 'cast(null as varchar2(4000))'
        else '''' || replace(parsed_korpus, '''', '''''') || ''''
    end
    || ' as sphere_korpus, '
    || case
        when parsed_stroenie is null then 'cast(null as varchar2(4000))'
        else '''' || replace(parsed_stroenie, '''', '''''') || ''''
    end
    || ' as sphere_stroenie from dual' as oracle_row
from test_objects
),

oracle_input as (
select
    string_agg(oracle_row, E'\nunion all\n' order by row_number) as input_rows
from oracle_rows
),

house_filter as (
select
    string_agg(
        '''' || replace(upper(parsed_house), '''', '''''') || '''',
        ', '
        order by upper(parsed_house)
    ) as value_list
from (
    select distinct parsed_house
    from test_objects
) values_for_filter
),

locality_filter as (
select
    string_agg(
        '''' || replace(upper(parsed_locality), '''', '''''') || '''',
        ', '
        order by upper(parsed_locality)
    ) as value_list
from (
    select distinct parsed_locality
    from test_objects
) values_for_filter
),

street_filter as (
select
    string_agg(
        '''' || replace(upper(parsed_street), '''', '''''') || '''',
        ', '
        order by upper(parsed_street)
    ) as value_list
from (
    select distinct parsed_street
    from test_objects
) values_for_filter
),

input_count as (
select count(*) as object_count
from test_objects
)

select
case
    when input_count.object_count = 0 then
        'Не найдено объектов, у которых одновременно есть разбираемый адрес и числовая площадь.'
    else
        $oracle$with sphere_objects as (
$oracle$
        || oracle_input.input_rows
        || $oracle$
),

egrn_candidates as (
select /*+ materialize */
    e.cad_ind,
    e.cadaster,
    e.building_type,
    e.egrn_address,
    e.object_status,
    e.oks_type,
    e.oks_purpose,
    e.square,
    e.measure,
    e.price,
    e.comissioning_year,
    e.construction_complete_year,
    e.floor_capacity_map,
    e.wall_material_short,
    e.row_update_date,
    e.ias_update_date,
    regexp_replace(replace(lower(trim(e.city)), 'ё', 'е'), '[[:space:]]+', ' ')
        as egrn_city,
    regexp_replace(replace(lower(trim(e.settlement)), 'ё', 'е'), '[[:space:]]+', ' ')
        as egrn_settlement,
    regexp_replace(replace(lower(trim(e.street)), 'ё', 'е'), '[[:space:]]+', ' ')
        as egrn_street,
    replace(
        regexp_replace(replace(lower(trim(e.house_number)), 'ё', 'е'), '[[:space:]]+', ' '),
        ' ',
        ''
    ) as egrn_house,
    replace(
        regexp_replace(replace(lower(trim(e.korpus)), 'ё', 'е'), '[[:space:]]+', ' '),
        ' ',
        ''
    ) as egrn_korpus,
    replace(
        regexp_replace(replace(lower(trim(e.stroenie)), 'ё', 'е'), '[[:space:]]+', ' '),
        ' ',
        ''
    ) as egrn_stroenie
from dm_risk_avatar.egrn_data e
where replace(upper(trim(e.house_number)), 'Ё', 'Е') in ($oracle$
        || house_filter.value_list
        || $oracle$)
  and (
      replace(upper(trim(e.city)), 'Ё', 'Е') in ($oracle$
        || locality_filter.value_list
        || $oracle$)
      or replace(upper(trim(e.settlement)), 'Ё', 'Е') in ($oracle$
        || locality_filter.value_list
        || $oracle$)
  )
  and replace(upper(trim(e.street)), 'Ё', 'Е') in ($oracle$
        || street_filter.value_list
        || $oracle$)
),

address_matches as (
select
    sphere.sphere_object_id,
    sphere.sphere_area,
    sphere.sphere_locality
        || ', ' || sphere.sphere_street
        || ', ' || sphere.sphere_house
        || case
            when sphere.sphere_korpus is not null
                then ', корпус ' || sphere.sphere_korpus
            else ''
        end
        || case
            when sphere.sphere_stroenie is not null
                then ', строение ' || sphere.sphere_stroenie
            else ''
        end as sphere_address_for_match,
    coalesce(
        nullif(trim(egrn.cadaster), ''),
        'CAD_IND:' || to_char(egrn.cad_ind)
    ) as egrn_key,
    egrn.cad_ind,
    egrn.cadaster,
    egrn.building_type,
    egrn.egrn_address,
    egrn.object_status,
    egrn.oks_type,
    egrn.oks_purpose,
    egrn.square as egrn_area,
    egrn.measure,
    egrn.price,
    egrn.comissioning_year,
    egrn.construction_complete_year,
    egrn.floor_capacity_map,
    egrn.wall_material_short,
    egrn.row_update_date,
    egrn.ias_update_date
from sphere_objects sphere
join egrn_candidates egrn
    on egrn.egrn_house = sphere.sphere_house
   and egrn.egrn_street = sphere.sphere_street
   and (
       egrn.egrn_city = sphere.sphere_locality
       or egrn.egrn_settlement = sphere.sphere_locality
   )
   and (
       sphere.sphere_korpus is null
       or egrn.egrn_korpus = sphere.sphere_korpus
   )
   and (
       sphere.sphere_stroenie is null
       or egrn.egrn_stroenie = sphere.sphere_stroenie
   )
where egrn.cadaster is not null
   or egrn.cad_ind is not null
),

ranked_source_rows as (
select
    address_matches.*,
    count(*) over (
        partition by sphere_object_id, egrn_key
    ) as source_row_count,
    row_number() over (
        partition by sphere_object_id, egrn_key
        order by
            abs(egrn_area - sphere_area) asc nulls last,
            row_update_date desc nulls last,
            ias_update_date desc nulls last,
            cad_ind desc nulls last
    ) as source_row_number
from address_matches
),

one_row_per_cadastral_object as (
select
    sphere_object_id,
    sphere_area,
    sphere_address_for_match,
    egrn_key,
    cad_ind,
    cadaster,
    building_type,
    egrn_address,
    object_status,
    oks_type,
    oks_purpose,
    egrn_area,
    measure,
    price,
    comissioning_year,
    construction_complete_year,
    floor_capacity_map,
    wall_material_short,
    abs(egrn_area - sphere_area) as minimum_area_difference,
    case
        when sphere_area > 0 and egrn_area is not null
            then 100 * abs(egrn_area - sphere_area) / sphere_area
    end as minimum_area_difference_percent,
    source_row_count
from ranked_source_rows
where source_row_number = 1
),

address_summary as (
select
    sphere_object_id,
    count(*) as address_candidate_count
from one_row_per_cadastral_object
group by sphere_object_id
),

area_summary as (
select
    sphere_object_id,
    count(case
        when minimum_area_difference <= 0.1 then 1
    end) as candidates_within_point_one_sq_m,
    count(case
        when minimum_area_difference <= 1 then 1
    end) as candidates_within_one_sq_m,
    count(case
        when minimum_area_difference_percent <= 1 then 1
    end) as candidates_within_one_percent,
    count(case
        when minimum_area_difference <= greatest(1, sphere_area * 0.01) then 1
    end) as candidates_within_working_tolerance
from one_row_per_cadastral_object
group by sphere_object_id
),

matched_after_area as (
select
    candidate.*,
    count(*) over (
        partition by sphere_object_id
    ) as candidate_count,
    row_number() over (
        partition by sphere_object_id
        order by
            minimum_area_difference asc nulls last,
            egrn_key
    ) as candidate_number
from one_row_per_cadastral_object candidate
where minimum_area_difference <= greatest(1, sphere_area * 0.01)
)

select
    sphere_object_id as "ID объекта Сферы",
    sphere_address_for_match as "Адрес Сферы для поиска",
    sphere_area as "Площадь Сферы",
    case
        when candidate_count = 1 then '1 к 1'
        else '1 ко многим'
    end as "Тип связи",
    candidate_count as "Всего кандидатов после площади",
    candidate_number as "Номер показанного кандидата",
    cadaster as "Кадастровый номер",
    cad_ind as "Внутренний ID ЕГРН",
    egrn_address as "Адрес ЕГРН",
    building_type as "Тип строения",
    oks_type as "Тип объекта ЕГРН",
    oks_purpose as "Назначение объекта ЕГРН",
    egrn_area as "Площадь ЕГРН",
    measure as "Единица площади ЕГРН",
    round(minimum_area_difference, 3) as "Разница площади",
    round(minimum_area_difference_percent, 3) as "Разница площади, процентов",
    price as "Кадастровая стоимость",
    comissioning_year as "Год ввода",
    construction_complete_year as "Год завершения строительства",
    floor_capacity_map as "Этажность",
    wall_material_short as "Материал стен",
    object_status as "Статус объекта ЕГРН",
    source_row_count as "Строк ЕГРН с тем же ключом"
from matched_after_area
where candidate_number <= 10
order by
    case when candidate_count = 1 then 1 else 2 end,
    sphere_object_id,
    candidate_number$oracle$
end as "Oracle запрос"
from oracle_input
cross join house_filter
cross join locality_filter
cross join street_filter
cross join input_count;
