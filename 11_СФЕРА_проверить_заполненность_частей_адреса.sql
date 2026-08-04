/*
ЗАПУСКАТЬ ТОЛЬКО В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Запрос ничего не выгружает из КХД и не показывает сами адреса.
Он только считает, какие части адреса заполнены у 20 объектов,
которые использовались в проверке точного совпадения.
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
) as object_address,
nullif(btrim(geo.postal_code), '') as postal_code,
nullif(btrim(geo.area), '') as area,
nullif(btrim(geo.settlement), '') as settlement,
nullif(btrim(geo.street), '') as street,
nullif(btrim(geo.house), '') as house,
nullif(btrim(geo.building), '') as building,
nullif(btrim(geo.block), '') as block,
geo.latitude,
geo.longitude,
nullif(btrim(geo.address_dgis_id), '') as address_dgis_id
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
)
select
count(*) as "Объектов в проверке",
count(*) filter (
where object_address is not null
) as "Есть полный адрес",
count(*) filter (
where postal_code is not null
) as "Есть индекс",
count(*) filter (
where area is not null
) as "Есть район",
count(*) filter (
where settlement is not null
) as "Есть населенный пункт",
count(*) filter (
where street is not null
) as "Есть улица",
count(*) filter (
where house is not null
) as "Есть дом",
count(*) filter (
where building is not null
) as "Есть строение",
count(*) filter (
where block is not null
) as "Есть корпус",
count(*) filter (
where street is not null
and house is not null
) as "Есть улица и дом",
count(*) filter (
where settlement is not null
and street is not null
and house is not null
) as "Есть населенный пункт, улица и дом",
count(*) filter (
where postal_code is not null
and street is not null
and house is not null
) as "Есть индекс, улица и дом",
count(*) filter (
where latitude is not null
and longitude is not null
) as "Есть координаты",
count(*) filter (
where address_dgis_id is not null
) as "Есть ID 2ГИС"
from test_objects;
