/*
ЗАПУСКАТЬ В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Этот файл создаст 4 отдельных Oracle-запроса.
Они запускаются в КХД по одному, по порядку.

Важно:
- не запускать все 4 строки как один SQL;
- копировать только ячейку "Oracle запрос" нужного шага;
- все запросы только читают данные;
- в каждом шаге используются те же 30 договоров.
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
|| chr(39)
|| replace(contract_id::text, chr(39), chr(39) || chr(39))
|| chr(39)
|| ' as sphere_contract_id, '
|| chr(39)
|| replace(btrim(contract_sbs_id), chr(39), chr(39) || chr(39))
|| chr(39)
|| ' as contract_sbs_id from dual'
as oracle_row
from test_population
),
oracle_input as (
select
'with sphere_contracts as ('
|| E'\n'
|| string_agg(
oracle_row,
E'\nunion all\n'
order by contract_id
)
|| E'\n)'
as input_cte
from oracle_rows
)
select
1 as "Порядок",
'Шаг 1. Договор, родитель и OBJECT_ID' as "Что проверяем",
input_cte
|| $q$
, matched_contracts as (
select distinct
s.sphere_contract_id,
c.contract_id,
c.parent_contract_id,
c.object_id
from sphere_contracts s
join dm_risk_avatar.contracts c
on c.contract_id = s.contract_sbs_id
),
parents_found as (
select distinct
m.sphere_contract_id
from matched_contracts m
join dm_risk_avatar.contracts p
on p.contract_id = m.parent_contract_id
where m.parent_contract_id is not null
)
select
(select count(*)
from dm_risk_avatar.contracts
where rownum = 1) as contracts_not_empty,
(select count(*)
from dm_risk_avatar.lnk_client_object_contract
where rownum = 1) as lnk_not_empty,
(select count(*)
from dm_risk_avatar.estate_objects
where rownum = 1) as estate_not_empty,
(select count(*)
from dm_risk_avatar.egrn_data
where rownum = 1) as egrn_not_empty,
(select count(*)
from dm_risk_avatar.stg_address_zud
where rownum = 1) as zud_not_empty,
(select count(*)
from dm_risk_avatar.stg_contract_objrisk
where rownum = 1) as objrisk_not_empty,
(select count(distinct sphere_contract_id)
from sphere_contracts) as total_contracts,
(select count(distinct sphere_contract_id)
from matched_contracts) as khd_contracts,
(select count(distinct sphere_contract_id)
from matched_contracts
where parent_contract_id is not null) as with_parent_id,
(select count(distinct sphere_contract_id)
from parents_found) as parent_found,
(select count(distinct sphere_contract_id)
from matched_contracts
where object_id is not null) as with_object_id
from dual$q$
as "Oracle запрос"
from oracle_input

union all

select
2 as "Порядок",
'Шаг 2. Связь договора с объектом' as "Что проверяем",
input_cte
|| $q$
, matched_contracts as (
select distinct
s.sphere_contract_id,
c.contract_id,
c.parent_contract_id
from sphere_contracts s
join dm_risk_avatar.contracts c
on c.contract_id = s.contract_sbs_id
),
contract_keys as (
select sphere_contract_id, contract_id, 'DIRECT' as key_type
from matched_contracts
union all
select sphere_contract_id, parent_contract_id, 'PARENT' as key_type
from matched_contracts
where parent_contract_id is not null
),
links as (
select distinct
k.sphere_contract_id,
k.key_type,
l.object_id,
l.object_category
from contract_keys k
join dm_risk_avatar.lnk_client_object_contract l
on l.contract_id = k.contract_id
)
select
(select count(distinct sphere_contract_id)
from matched_contracts) as khd_contracts,
(select count(distinct sphere_contract_id)
from links
where key_type = 'DIRECT') as lnk_direct_contracts,
(select count(distinct sphere_contract_id)
from links
where key_type = 'PARENT') as lnk_parent_contracts,
(select count(distinct sphere_contract_id)
from links) as contracts_with_links,
(select count(distinct object_id)
from links) as linked_objects
from dual$q$
as "Oracle запрос"
from oracle_input

union all

select
3 as "Порядок",
'Шаг 3. Объект недвижимости и ЕГРН' as "Что проверяем",
input_cte
|| $q$
, matched_contracts as (
select distinct
s.sphere_contract_id,
c.contract_id,
c.parent_contract_id
from sphere_contracts s
join dm_risk_avatar.contracts c
on c.contract_id = s.contract_sbs_id
),
contract_keys as (
select sphere_contract_id, contract_id
from matched_contracts
union
select sphere_contract_id, parent_contract_id
from matched_contracts
where parent_contract_id is not null
),
object_ids as (
select distinct
k.sphere_contract_id,
l.object_id
from contract_keys k
join dm_risk_avatar.lnk_client_object_contract l
on l.contract_id = k.contract_id
where l.object_id is not null
),
numeric_object_ids as (
select
sphere_contract_id,
object_id,
case
when regexp_like(object_id, '^[0-9]+$')
then to_number(object_id)
end as cad_ind
from object_ids
),
estate_matches as (
select distinct
o.sphere_contract_id,
e.cad_ind
from numeric_object_ids o
join dm_risk_avatar.estate_objects e
on e.cad_ind = o.cad_ind
where o.cad_ind is not null
union
select distinct
o.sphere_contract_id,
e.cad_ind
from object_ids o
join dm_risk_avatar.estate_objects e
on e.cadaster = o.object_id
),
egrn_matches as (
select distinct
m.sphere_contract_id,
e.cad_ind
from estate_matches m
join dm_risk_avatar.egrn_data e
on e.cad_ind = m.cad_ind
)
select
(select count(distinct sphere_contract_id)
from object_ids) as contracts_with_object_id,
(select count(distinct object_id)
from object_ids) as object_ids,
(select count(distinct sphere_contract_id)
from estate_matches) as estate_contracts,
(select count(distinct cad_ind)
from estate_matches) as estate_objects,
(select count(distinct sphere_contract_id)
from egrn_matches) as egrn_contracts,
(select count(distinct cad_ind)
from egrn_matches) as egrn_objects
from dual$q$
as "Oracle запрос"
from oracle_input

union all

select
4 as "Порядок",
'Шаг 4. Альтернативный путь через адрес' as "Что проверяем",
input_cte
|| $q$
, matched_contracts as (
select distinct
s.sphere_contract_id,
c.contract_id,
c.parent_contract_id
from sphere_contracts s
join dm_risk_avatar.contracts c
on c.contract_id = s.contract_sbs_id
),
contract_keys as (
select sphere_contract_id, contract_id, 'DIRECT' as key_type
from matched_contracts
union all
select sphere_contract_id, parent_contract_id, 'PARENT' as key_type
from matched_contracts
where parent_contract_id is not null
),
zud_matches as (
select distinct
k.sphere_contract_id,
k.key_type,
z.fias_id_house
from contract_keys k
join dm_risk_avatar.stg_address_zud z
on z.contract_id = k.contract_id
),
objrisk_matches as (
select distinct
k.sphere_contract_id,
k.key_type
from contract_keys k
join dm_risk_avatar.stg_contract_objrisk o
on o.contract_id = k.contract_id
),
lnk_objects as (
select distinct
k.sphere_contract_id,
l.object_id
from contract_keys k
join dm_risk_avatar.lnk_client_object_contract l
on l.contract_id = k.contract_id
where l.object_id is not null
),
address_matches as (
select distinct
l.sphere_contract_id,
a.fias_id_house
from lnk_objects l
join dm_risk_avatar.stg_address_zud_hash a
on a.address_hash = l.object_id
),
all_fias as (
select sphere_contract_id, fias_id_house
from zud_matches
where fias_id_house is not null
union
select sphere_contract_id, fias_id_house
from address_matches
where fias_id_house is not null
),
egrn_matches as (
select distinct
f.sphere_contract_id,
e.cad_ind
from all_fias f
join dm_risk_avatar.egrn_data e
on e.fias_id_house = f.fias_id_house
)
select
(select count(distinct sphere_contract_id)
from zud_matches
where key_type = 'DIRECT') as zud_direct_contracts,
(select count(distinct sphere_contract_id)
from zud_matches
where key_type = 'PARENT') as zud_parent_contracts,
(select count(distinct sphere_contract_id)
from objrisk_matches
where key_type = 'DIRECT') as objrisk_direct_contracts,
(select count(distinct sphere_contract_id)
from objrisk_matches
where key_type = 'PARENT') as objrisk_parent_contracts,
(select count(distinct sphere_contract_id)
from address_matches) as lnk_address_contracts,
(select count(distinct sphere_contract_id)
from egrn_matches) as egrn_contracts
from dual$q$
as "Oracle запрос"
from oracle_input

order by "Порядок";
