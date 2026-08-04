/*
ЗАПУСКАТЬ В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Это один запрос для следующего шага.

Что он проверит в КХД на 30 договорах:
1. Есть ли договор в STG_ADDRESS_ZUD.
2. Есть ли нормализованный адрес в STG_ADDRESS_ZUD_HASH.
3. Есть ли объект в STG_CONTRACT_OBJRISK.
4. Можно ли по FIAS_ID_HOUSE найти недвижимость в EGRN_DATA.

Порядок:
1. Выполнить весь файл в "Сфере".
2. Скопировать ячейку "Готовый Oracle запрос".
3. Вставить её в пустой редактор подключения КХД 1.0.
4. Выполнить в Oracle.
*/

with task_candidates as (
select
c.id as contract_id,
c.sbs_id as contract_sbs_id,
c.core_id,
c.n_contract,
c.n_contract_cleaned,
r.last_request_ins_task_policy_num as request_policy_number,
t.contract_num_policy as task_policy_number,
t.contract_num_policy_1c as task_policy_number_1c,
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
select *
from task_candidates
where task_rank = 1
),
population as (
select task.*
from selected_tasks task
where nullif(btrim(contract_sbs_id), '') is not null
and exists (
select 1
from bps_request_ins_task_insurance_object tobj
join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
join base_insurance_object obj
on obj.id = ch.insurance_object_id
where tobj.parent_id = task.task_id
and obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
)
),
test_population as (
select *
from population
order by
(
case when contract_sbs_id is not null then 1 else 0 end
+ case when core_id is not null then 1 else 0 end
+ case when n_contract is not null then 1 else 0 end
+ case when n_contract_cleaned is not null then 1 else 0 end
+ case when task_policy_number is not null then 1 else 0 end
+ case when task_policy_number_1c is not null then 1 else 0 end
+ case when request_policy_number is not null then 1 else 0 end
) desc,
contract_id desc
limit 30
),
oracle_rows as (
select
contract_id,
'select '
|| case
when contract_id is null then 'null'
else chr(39)
|| replace(contract_id::text, chr(39), chr(39) || chr(39))
|| chr(39)
end
|| ' as sphere_contract_id, '
|| case
when nullif(btrim(contract_sbs_id), '') is null then 'null'
else chr(39)
|| replace(btrim(contract_sbs_id), chr(39), chr(39) || chr(39))
|| chr(39)
end
|| ' as contract_sbs_id from dual'
as oracle_row
from test_population
)
select
$oracle$
with sphere_contracts as (
$oracle$
|| string_agg(
oracle_row,
E'\nunion all\n'
order by contract_id
)
|| $oracle$
),
zud as (
select
s.sphere_contract_id,
z.contract_id,
z.address,
z.fias_id_house
from sphere_contracts s
join dm_risk_avatar.stg_address_zud z
on trim(z.contract_id) = trim(s.contract_sbs_id)
),
zud_hash as (
select
s.sphere_contract_id,
z.contract_id,
z.address,
z.fias_id_house,
z.geo_latitude,
z.geo_longitude
from sphere_contracts s
join dm_risk_avatar.stg_address_zud_hash z
on trim(z.contract_id) = trim(s.contract_sbs_id)
),
objrisk as (
select
s.sphere_contract_id,
o.contract_id,
o.insured_obj_id,
o.obj_address,
o.obj_type
from sphere_contracts s
join dm_risk_avatar.stg_contract_objrisk o
on trim(o.contract_id) = trim(s.contract_sbs_id)
),
egrn_from_zud as (
select distinct
z.sphere_contract_id,
e.cadaster
from zud z
join dm_risk_avatar.egrn_data e
on trim(e.fias_id_house) = trim(z.fias_id_house)
where z.fias_id_house is not null
),
egrn_from_hash as (
select distinct
z.sphere_contract_id,
e.cadaster
from zud_hash z
join dm_risk_avatar.egrn_data e
on trim(e.fias_id_house) = trim(z.fias_id_house)
where z.fias_id_house is not null
)
select
(select count(distinct sphere_contract_id)
from sphere_contracts) as total_contracts,
(select count(distinct sphere_contract_id)
from zud) as zud_contracts,
(select count(*) from zud) as zud_rows,
(select count(distinct sphere_contract_id)
from zud
where trim(address) is not null) as zud_with_address,
(select count(distinct sphere_contract_id)
from zud
where trim(fias_id_house) is not null) as zud_with_fias,
(select count(distinct sphere_contract_id)
from zud_hash) as hash_contracts,
(select count(distinct sphere_contract_id)
from zud_hash
where trim(address) is not null) as hash_with_address,
(select count(distinct sphere_contract_id)
from zud_hash
where trim(fias_id_house) is not null) as hash_with_fias,
(select count(distinct sphere_contract_id)
from zud_hash
where geo_latitude is not null
and geo_longitude is not null) as hash_with_coords,
(select count(distinct sphere_contract_id)
from objrisk) as objrisk_contracts,
(select count(distinct insured_obj_id)
from objrisk) as objrisk_objects,
(select count(distinct sphere_contract_id)
from objrisk
where trim(obj_address) is not null) as objrisk_with_address,
(select count(distinct sphere_contract_id)
from egrn_from_zud) as egrn_zud_contracts,
(select count(distinct sphere_contract_id)
from egrn_from_hash) as egrn_hash_contracts,
(select count(distinct cadaster)
from egrn_from_zud) as egrn_zud_cadasters,
(select count(distinct cadaster)
from egrn_from_hash) as egrn_hash_cadasters
from dual
$oracle$
as "Готовый Oracle запрос"
from oracle_rows;
