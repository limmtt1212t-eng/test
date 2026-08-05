/*
ЗАПУСКАТЬ В DBeaver В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Что делает файл:
1. Берёт 20 последних объектов, для которых удалось выделить:
   населённый пункт, улицу и дом.
2. Формирует один готовый Oracle-запрос.
3. Сам этот файл BUILDINGS не проверяет.

После запуска:
1. В результате будет одна ячейка "Oracle запрос".
2. Скопировать содержимое ячейки целиком.
3. Выполнить его в Oracle.

Oracle-запрос вернёт только количества, без адресов и идентификаторов.
*/

with task_candidates as (
select
c.id as contract_id,
coalesce(
t.d_conclusion_ins_contract::timestamp with time zone,
c.d_sign_contract,
t.d_create
) as as_of_date,
t.id as task_id,
row_number() over (
partition by c.id
order by
t.d_conclusion_ins_contract desc nulls last,
t.d_create desc nulls last,
t.d_change desc nulls last,
t.id desc
) as task_rank
from bps_request_ins_task t
join bps_request_ins r
on r.id = t.request_ins_id
join bps_contract c
on c.id = r.contract_id
where t.task_type = 'draft_contract'
and t.status = 'operational_archive'
and (
t.ins_document_type = 'new_ins_contract'
or t.ins_document_type = 'ins_contract_prolong'
or t.ins_document_type is null
)
and t.ins_refuse is not true
and t.d_delete is null
and r.d_delete is null
and c.d_delete is null
),

selected_tasks as (
select
contract_id,
as_of_date,
task_id
from task_candidates
where task_rank = 1
),

object_candidates as (
select
task.contract_id,
task.as_of_date,
obj.id as object_id,
coalesce(
nullif(btrim(geo.full_address), ''),
nullif(btrim(obj.original_address), '')
) as source_address,
nullif(btrim(geo.area), '') as sphere_rayon,
nullif(btrim(geo.settlement), '') as sphere_settlement,
nullif(btrim(geo.street), '') as sphere_street,
nullif(btrim(geo.house), '') as sphere_house,
nullif(btrim(geo.building), '') as sphere_stroenie,
nullif(btrim(geo.block), '') as sphere_korpus,
row_number() over (
partition by task.task_id, obj.id
order by
tobj.d_change desc nulls last,
tobj.d_create desc nulls last,
ch.version_start_date desc nulls last,
ch.version_number desc nulls last,
tobj.id desc,
ch.id desc
) as object_rank
from selected_tasks task
join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = task.task_id
join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
join base_insurance_object obj
on obj.id = ch.insurance_object_id
left join base_geo_address geo
on geo.id = obj.geo_address_id
where obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
),

one_row_per_object as (
select *
from object_candidates
where object_rank = 1
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
),

parsed as (
select
normalized.*,
coalesce(
(regexp_match(address_lower, '(?:^|, )([^,]+?) (?:область|обл|край|республика|респ)(?:,|$)'))[1],
(regexp_match(address_lower, '(?:^|, )(?:область|обл|край|республика|респ) ([^,]+)(?:,|$)'))[1]
) as parsed_region,
coalesce(
(regexp_match(address_lower, '(?:^|, )(?:г|город) ([^,]+)(?:,|$)'))[1],
sphere_settlement,
(regexp_match(address_lower, '(?:^|, )(?:пгт|поселок городского типа|рп|рабочий поселок|пос|поселок|с|село|д|деревня) ([^,]+)(?:,|$)'))[1],
(regexp_match(address_lower, '(?:^|, )([^,]+), (?:[^,]+ (?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея)|(?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея) [^,]+)(?:,|$)'))[1]
) as parsed_locality,
coalesce(
sphere_street,
(regexp_match(address_lower, '(?:^|, )(?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея) ([^,]+)(?:,|$)'))[1],
(regexp_match(address_lower, '(?:^|, )([^,]+?) (?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея)(?:,|$)'))[1]
) as parsed_street,
coalesce(
sphere_house,
(regexp_match(address_lower, '(?:^|, )(?:д|дом) *([0-9]+[а-яa-z]?(?:[/-][0-9а-яa-z]+)?)(?:,|$)'))[1],
(regexp_match(address_lower, '(?:^|, )([0-9]+[а-яa-z]?(?:[/-][0-9а-яa-z]+)?)$'))[1]
) as parsed_house,
coalesce(
sphere_korpus,
(regexp_match(address_lower, '(?:^|, )(?:корп|корпус|к) *([0-9а-яa-z/-]+)(?:,|$)'))[1]
) as parsed_korpus,
coalesce(
sphere_stroenie,
(regexp_match(address_lower, '(?:^|, )(?:стр|строение) *([0-9а-яa-z/-]+)(?:,|$)'))[1]
) as parsed_stroenie
from normalized
),

prepared as (
select
contract_id,
as_of_date,
object_id::text as object_id,
nullif(btrim(replace(lower(parsed_region), 'ё', 'е')), '') as parsed_region,
nullif(btrim(replace(lower(parsed_locality), 'ё', 'е')), '') as parsed_locality,
nullif(btrim(replace(lower(parsed_street), 'ё', 'е')), '') as parsed_street,
nullif(
replace(
btrim(replace(lower(parsed_house), 'ё', 'е')),
' ',
''
),
''
) as parsed_house,
nullif(
replace(
btrim(replace(lower(parsed_korpus), 'ё', 'е')),
' ',
''
),
''
) as parsed_korpus,
nullif(
replace(
btrim(replace(lower(parsed_stroenie), 'ё', 'е')),
' ',
''
),
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
as_of_date desc nulls last,
contract_id desc,
object_id
limit 20
),

oracle_rows as (
select
row_number() over (
order by as_of_date desc nulls last, contract_id desc, object_id
) as row_number,
'select '
|| '''' || replace(object_id, '''', '''''') || ''' as sphere_object_id, '
|| case
when parsed_region is null then 'cast(null as varchar2(4000))'
else '''' || replace(parsed_region, '''', '''''') || ''''
end
|| ' as sphere_region, '
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
|| ' as sphere_stroenie from dual'
as oracle_row
from test_objects
),

oracle_input as (
select
string_agg(
oracle_row,
E'\nunion all\n'
order by row_number
) as input_rows
from oracle_rows
),

house_values as (
select distinct
upper(parsed_house) as house_number
from test_objects
),

oracle_house_filter as (
select
string_agg(
'''' || replace(house_number, '''', '''''') || '''',
', '
order by house_number
) as house_list
from house_values
),

input_count as (
select count(*) as object_count
from test_objects
)

select
case
when input_count.object_count = 0 then
'Не найдено объектов, у которых одновременно выделены населённый пункт, улица и дом.'
else
$q$with sphere_objects as (
$q$
|| oracle_input.input_rows
|| $q$
),
building_candidates as (
select
b.cad_ind,
b.cadaster,
b.fias_id_house,
b.address,
regexp_replace(replace(lower(trim(b.region)), 'ё', 'е'), '[[:space:]]+', ' ') as building_region,
regexp_replace(replace(lower(trim(b.city)), 'ё', 'е'), '[[:space:]]+', ' ') as building_city,
regexp_replace(replace(lower(trim(b.settlement)), 'ё', 'е'), '[[:space:]]+', ' ') as building_settlement,
regexp_replace(replace(lower(trim(b.street)), 'ё', 'е'), '[[:space:]]+', ' ') as building_street,
replace(regexp_replace(replace(lower(trim(b.house_number)), 'ё', 'е'), '[[:space:]]+', ' '), ' ', '') as building_house,
replace(regexp_replace(replace(lower(trim(b.korpus)), 'ё', 'е'), '[[:space:]]+', ' '), ' ', '') as building_korpus,
replace(regexp_replace(replace(lower(trim(b.stroenie)), 'ё', 'е'), '[[:space:]]+', ' '), ' ', '') as building_stroenie
from dm_risk_avatar.buildings b
where b.house_number in ($q$
|| oracle_house_filter.house_list
|| $q$)
),
building_matches as (
select distinct
s.sphere_object_id,
b.cad_ind,
b.cadaster,
b.fias_id_house,
b.address,
case
when s.sphere_region is not null
and b.building_region = s.sphere_region then 1
else 0
end as region_confirmed
from sphere_objects s
join building_candidates b
on b.building_house = s.sphere_house
and b.building_street = s.sphere_street
and (
b.building_city = s.sphere_locality
or b.building_settlement = s.sphere_locality
)
and (
s.sphere_korpus is null
or b.building_korpus = s.sphere_korpus
)
and (
s.sphere_stroenie is null
or b.building_stroenie = s.sphere_stroenie
)
),
candidate_counts as (
select
sphere_object_id,
count(
distinct coalesce(
to_char(cad_ind),
fias_id_house,
cadaster,
address
)
) as candidate_count,
max(region_confirmed) as region_confirmed
from building_matches
group by sphere_object_id
)
select
(select count(*) from sphere_objects) as input_objects,
(select count(*) from candidate_counts) as matched_objects,
(select count(*) from candidate_counts where candidate_count = 1) as unique_matches,
(select count(*) from candidate_counts where candidate_count > 1) as ambiguous_matches,
(select count(*) from sphere_objects)
- (select count(*) from candidate_counts) as unmatched_objects,
(select count(distinct coalesce(to_char(cad_ind), fias_id_house, cadaster, address))
from building_matches) as building_candidates,
(select count(distinct sphere_object_id)
from building_matches
where region_confirmed = 1) as region_confirmed_objects,
(select count(distinct sphere_object_id)
from building_matches
where fias_id_house is not null) as objects_with_fias,
(select count(distinct sphere_object_id)
from building_matches
where cadaster is not null) as objects_with_cadaster
from dual$q$
end as "Oracle запрос"
from oracle_input
cross join oracle_house_filter
cross join input_count;
