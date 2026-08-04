/*
ЗАПУСКАТЬ В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Это один запрос. Он создаст короткий Oracle-запрос для проверки 30 договоров.

Что проверяется в КХД:
1. Не пусты ли сами нужные таблицы КХД.
2. PARENT_CONTRACT_ID — родительский договор.
3. CONTRACTS.OBJECT_ID — объект, записанный прямо в договоре.
4. LNK_CLIENT_OBJECT_CONTRACT — отдельная таблица связей.
5. OBJECT_ID как возможный CAD_IND, CADASTER или ADDRESS_HASH.
6. Доходит ли найденный объект или адрес до EGRN_DATA.
7. Адреса и объекты, привязанные к родительскому договору.

Порядок:
1. Выполнить весь файл в "Сфере".
2. Скопировать ячейку "Готовый Oracle запрос".
3. Вставить в пустой редактор подключения КХД 1.0.
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
matched_contracts as (
select distinct
s.sphere_contract_id,
c.contract_id,
c.parent_contract_id,
c.object_id,
c.client_id
from sphere_contracts s
join dm_risk_avatar.contracts c
on trim(c.contract_id) = trim(s.contract_sbs_id)
),
parents_found as (
select distinct
m.sphere_contract_id,
p.contract_id
from matched_contracts m
join dm_risk_avatar.contracts p
on trim(p.contract_id) = trim(m.parent_contract_id)
where m.parent_contract_id is not null
),
lnk_direct as (
select distinct
m.sphere_contract_id,
l.object_id,
l.object_category,
l.datasource
from matched_contracts m
join dm_risk_avatar.lnk_client_object_contract l
on trim(l.contract_id) = trim(m.contract_id)
),
lnk_parent as (
select distinct
m.sphere_contract_id,
l.object_id,
l.object_category,
l.datasource
from matched_contracts m
join dm_risk_avatar.lnk_client_object_contract l
on trim(l.contract_id) = trim(m.parent_contract_id)
where m.parent_contract_id is not null
),
lnk_all as (
select * from lnk_direct
union
select * from lnk_parent
),
contract_object_to_estate as (
select distinct
m.sphere_contract_id,
e.cad_ind,
e.cadaster
from matched_contracts m
join dm_risk_avatar.estate_objects e
on e.cad_ind = case
when regexp_like(trim(m.object_id), '^[0-9]+$')
then to_number(trim(m.object_id))
end
),
contract_object_to_cadaster as (
select distinct
m.sphere_contract_id,
e.cad_ind,
e.cadaster
from matched_contracts m
join dm_risk_avatar.estate_objects e
on trim(e.cadaster) = trim(m.object_id)
where m.object_id is not null
),
contract_estate_all as (
select sphere_contract_id, cad_ind
from contract_object_to_estate
union
select sphere_contract_id, cad_ind
from contract_object_to_cadaster
),
contract_object_egrn as (
select distinct
x.sphere_contract_id,
e.cad_ind
from contract_estate_all x
join dm_risk_avatar.egrn_data e
on e.cad_ind = x.cad_ind
),
lnk_object_to_estate as (
select distinct
l.sphere_contract_id,
e.cad_ind,
e.cadaster
from lnk_all l
join dm_risk_avatar.estate_objects e
on e.cad_ind = case
when regexp_like(trim(l.object_id), '^[0-9]+$')
then to_number(trim(l.object_id))
end
),
lnk_object_to_cadaster as (
select distinct
l.sphere_contract_id,
e.cad_ind,
e.cadaster
from lnk_all l
join dm_risk_avatar.estate_objects e
on trim(e.cadaster) = trim(l.object_id)
where l.object_id is not null
),
lnk_estate_all as (
select sphere_contract_id, cad_ind
from lnk_object_to_estate
union
select sphere_contract_id, cad_ind
from lnk_object_to_cadaster
),
lnk_object_egrn as (
select distinct
x.sphere_contract_id,
e.cad_ind
from lnk_estate_all x
join dm_risk_avatar.egrn_data e
on e.cad_ind = x.cad_ind
),
lnk_object_to_address as (
select distinct
l.sphere_contract_id,
a.address_hash,
a.fias_id_house
from lnk_all l
join dm_risk_avatar.stg_address_zud_hash a
on trim(a.address_hash) = trim(l.object_id)
where l.object_id is not null
),
egrn_from_lnk_address as (
select distinct
a.sphere_contract_id,
e.cadaster
from lnk_object_to_address a
join dm_risk_avatar.egrn_data e
on trim(e.fias_id_house) = trim(a.fias_id_house)
where a.fias_id_house is not null
),
parent_zud as (
select distinct
m.sphere_contract_id,
z.contract_id,
z.fias_id_house
from matched_contracts m
join dm_risk_avatar.stg_address_zud z
on trim(z.contract_id) = trim(m.parent_contract_id)
where m.parent_contract_id is not null
),
egrn_from_parent_zud as (
select distinct
z.sphere_contract_id,
e.cad_ind
from parent_zud z
join dm_risk_avatar.egrn_data e
on trim(e.fias_id_house) = trim(z.fias_id_house)
where z.fias_id_house is not null
),
parent_objrisk as (
select distinct
m.sphere_contract_id,
o.contract_id
from matched_contracts m
join dm_risk_avatar.stg_contract_objrisk o
on trim(o.contract_id) = trim(m.parent_contract_id)
where m.parent_contract_id is not null
)
select
(select count(*)
from dm_risk_avatar.contracts where rownum = 1)
as contracts_not_empty,
(select count(*)
from dm_risk_avatar.lnk_client_object_contract where rownum = 1)
as lnk_not_empty,
(select count(*)
from dm_risk_avatar.estate_objects where rownum = 1)
as estate_not_empty,
(select count(*)
from dm_risk_avatar.egrn_data where rownum = 1)
as egrn_not_empty,
(select count(*)
from dm_risk_avatar.stg_address_zud where rownum = 1)
as zud_not_empty,
(select count(*)
from dm_risk_avatar.stg_contract_objrisk where rownum = 1)
as objrisk_not_empty,
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
where object_id is not null) as with_object_id,
(select count(distinct sphere_contract_id)
from contract_object_to_estate) as contract_obj_cadind,
(select count(distinct sphere_contract_id)
from contract_object_to_cadaster) as contract_obj_cadnum,
(select count(distinct sphere_contract_id)
from contract_object_egrn) as contract_obj_egrn,
(select count(distinct sphere_contract_id)
from lnk_direct) as lnk_direct_contracts,
(select count(distinct sphere_contract_id)
from lnk_parent) as lnk_parent_contracts,
(select count(distinct object_id)
from lnk_all) as lnk_objects,
(select count(distinct sphere_contract_id)
from lnk_object_to_estate) as lnk_obj_cadind,
(select count(distinct sphere_contract_id)
from lnk_object_to_cadaster) as lnk_obj_cadnum,
(select count(distinct sphere_contract_id)
from lnk_object_egrn) as lnk_obj_egrn,
(select count(distinct sphere_contract_id)
from lnk_object_to_address) as lnk_obj_address,
(select count(distinct sphere_contract_id)
from egrn_from_lnk_address) as lnk_address_egrn,
(select count(distinct sphere_contract_id)
from parent_zud) as parent_zud_contracts,
(select count(distinct sphere_contract_id)
from egrn_from_parent_zud) as parent_zud_egrn,
(select count(distinct sphere_contract_id)
from parent_objrisk) as parent_objrisk_contracts
from dual
$oracle$
as "Готовый Oracle запрос"
from oracle_rows;
