/*
ЗАПУСКАТЬ В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Цель: проверить связь объекта "Сферы" с ЕГРН по адресу.

Файл берёт 20 свежих объектов недвижимости с заполненным
адресом и создаёт 3 отдельных Oracle-запроса.

Порядок:
1. Выполнить весь этот файл в "Сфере".
2. В результате будет 3 строки.
3. Скопировать только ячейку "Oracle запрос" из строки "Шаг 1".
4. Вставить её в пустой редактор КХД Oracle и выполнить.
5. Шаги 2 и 3 пока не запускать.

Запросы только читают данные.
*/

with task_candidates as (
select
c.id as contract_id,
t.id as task_id,
coalesce(
t.d_conclusion_ins_contract::timestamp with time zone,
c.d_sign_contract,
t.d_create
) as as_of_date,
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
select *
from task_candidates
where task_rank = 1
),
object_candidates as (
select distinct
task.contract_id,
task.task_id,
task.as_of_date,
obj.id as object_id,
coalesce(
nullif(btrim(geo.full_address), ''),
nullif(btrim(obj.original_address), '')
) as object_address
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
and coalesce(
nullif(btrim(geo.full_address), ''),
nullif(btrim(obj.original_address), '')
) is not null
),
test_objects as (
select *
from object_candidates
order by
as_of_date desc nulls last,
contract_id desc,
object_id
limit 20
),
oracle_rows as (
select
object_id,
'select '
|| chr(39)
|| replace(object_id::text, chr(39), chr(39) || chr(39))
|| chr(39)
|| ' as sphere_object_id, '
|| chr(39)
|| replace(object_address, chr(39), chr(39) || chr(39))
|| chr(39)
|| ' as sphere_address from dual'
as oracle_row
from test_objects
),
oracle_input as (
select
'with sphere_objects as ('
|| E'\n'
|| string_agg(
oracle_row,
E'\nunion all\n'
order by object_id
)
|| E'\n)'
as input_cte
from oracle_rows
)
select
1 as "Порядок",
'Шаг 1. Точное совпадение EGRN_ADDRESS' as "Что проверяем",
input_cte
|| $q$
, address_matches as (
select distinct
s.sphere_object_id,
e.cad_ind
from sphere_objects s
join dm_risk_avatar.egrn_data e
on e.egrn_address = s.sphere_address
),
candidate_counts as (
select
sphere_object_id,
count(distinct cad_ind) as candidate_count
from address_matches
group by sphere_object_id
)
select
(select count(distinct sphere_object_id)
from sphere_objects) as input_objects,
(select count(distinct sphere_address)
from sphere_objects) as input_addresses,
(select count(*)
from candidate_counts) as matched_objects,
(select count(*)
from candidate_counts
where candidate_count = 1) as unique_matches,
(select count(*)
from candidate_counts
where candidate_count > 1) as ambiguous_matches,
(select count(distinct cad_ind)
from address_matches) as egrn_candidates
from dual$q$
as "Oracle запрос"
from oracle_input

union all

select
2 as "Порядок",
'Шаг 2. Точное совпадение ADDRESS_SRC' as "Что проверяем",
input_cte
|| $q$
, address_matches as (
select distinct
s.sphere_object_id,
e.cad_ind
from sphere_objects s
join dm_risk_avatar.egrn_data e
on e.address_src = s.sphere_address
),
candidate_counts as (
select
sphere_object_id,
count(distinct cad_ind) as candidate_count
from address_matches
group by sphere_object_id
)
select
(select count(distinct sphere_object_id)
from sphere_objects) as input_objects,
(select count(*)
from candidate_counts) as matched_objects,
(select count(*)
from candidate_counts
where candidate_count = 1) as unique_matches,
(select count(*)
from candidate_counts
where candidate_count > 1) as ambiguous_matches,
(select count(distinct cad_ind)
from address_matches) as egrn_candidates
from dual$q$
as "Oracle запрос"
from oracle_input

union all

select
3 as "Порядок",
'Шаг 3. Адресный справочник и FIAS' as "Что проверяем",
input_cte
|| $q$
, dictionary_matches as (
select distinct
s.sphere_object_id,
a.address_hash,
a.fias_id_house
from sphere_objects s
join dm_risk_avatar.stg_address_zud_hash a
on a.address = s.sphere_address
),
candidate_counts as (
select
sphere_object_id,
count(distinct address_hash) as candidate_count
from dictionary_matches
group by sphere_object_id
)
select
(select count(distinct sphere_object_id)
from sphere_objects) as input_objects,
(select count(*)
from candidate_counts) as matched_objects,
(select count(*)
from candidate_counts
where candidate_count = 1) as unique_matches,
(select count(*)
from candidate_counts
where candidate_count > 1) as ambiguous_matches,
(select count(distinct sphere_object_id)
from dictionary_matches
where fias_id_house is not null) as objects_with_fias
from dual$q$
as "Oracle запрос"
from oracle_input

order by "Порядок";
