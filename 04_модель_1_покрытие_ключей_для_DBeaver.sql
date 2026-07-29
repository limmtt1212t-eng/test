with task_candidates as (
select
c.id as contract_id,
c.n_contract,
c.document_status,
c.d_sign_contract,
c.d_start_contract,
c.d_end_contract,
c.contractor_id,
r.id as request_id,
r.corporate_crm_id,
r.business_segment,
r.is_underwriter_involvement_required,
t.id as task_id,
t.d_create as task_create_date,
t.industry as task_industry,
t.subindustry as task_subindustry,
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
and t.d_delete is null
and r.d_delete is null
and c.d_delete is null
and t.ins_refuse is not true
),
property_tasks as (
select *
from task_candidates task
where task_rank = 1
and exists (
select 1
from bps_request_ins_task_insurance_object tobj_check
join base_insurance_object_characteristics ch_check
on ch_check.id = tobj_check.characteristics_id
join base_insurance_object obj_check
on obj_check.id = ch_check.insurance_object_id
where tobj_check.parent_id = task.task_id
and obj_check.elementary_obj_type = 'nedv_ul_and_ip'
and obj_check.d_delete is null
)
),
sampled_tasks as (
select *
from property_tasks
order by
d_sign_contract desc nulls last,
task_create_date desc nulls last,
contract_id desc
limit 1000
),
object_candidates as (
select
task.contract_id,
task.n_contract,
task.document_status,
task.d_sign_contract,
task.d_start_contract,
task.d_end_contract,
task.request_id,
task.task_id,
task.business_segment,
task.task_industry,
task.task_subindustry,
task.is_underwriter_involvement_required,
tobj.id as task_object_link_id,
tobj.insured_sum as object_insured_sum,
tobj.insured_sum_currency as object_insured_sum_currency,
ch.id as characteristics_id,
ch.insurance_value,
ch.insurance_value_currency,
ch.insurance_value_basis,
ch.is_pledged,
ch.pledged_value,
ch.characteristics,
obj.id as object_id,
obj.description as object_description,
obj.obj_type,
obj.elementary_obj_type,
obj.original_address,
geo.full_address,
geo.fias_code,
geo.latitude,
geo.longitude,
geo.address_dgis_id,
crm.industry as crm_industry,
crm.macroindustry as crm_macroindustry,
crm.okved as crm_okved,
crm.segment as crm_segment,
policyholder.inn as policyholder_inn,
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
from sampled_tasks task
join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = task.task_id
join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
join base_insurance_object obj
on obj.id = ch.insurance_object_id
left join base_geo_address geo
on geo.id = obj.geo_address_id
left join bps_corporate_crm crm
on crm.id = task.corporate_crm_id
left join bps_contractor policyholder
on policyholder.id = task.contractor_id
where obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
),
object_rows as (
select *
from object_candidates
where object_rank = 1
),
display_rows as (
select
object_rows.*,
count(*) over (
partition by contract_id
) as object_count,
row_number() over (
partition by contract_id
order by object_id
) as object_number
from object_rows
)
select
count(distinct contract_id) as "Договоров_проверено",
count(*) as "Объектов_проверено",
count(*) filter (
where nullif(regexp_replace(coalesce(policyholder_inn, ''), '[^0-9]', '', 'g'), '') is not null
) as "Объектов_с_ИНН",
round(
100.0 * count(*) filter (
where nullif(regexp_replace(coalesce(policyholder_inn, ''), '[^0-9]', '', 'g'), '') is not null
) / nullif(count(*), 0),
1
) as "ИНН_процент",
count(*) filter (
where nullif(btrim(fias_code), '') is not null
) as "Объектов_с_ФИАС",
round(
100.0 * count(*) filter (
where nullif(btrim(fias_code), '') is not null
) / nullif(count(*), 0),
1
) as "ФИАС_процент",
count(*) filter (
where nullif(btrim(fias_code), '') is null
) as "Объектов_без_ФИАС",
round(
100.0 * count(*) filter (
where nullif(btrim(fias_code), '') is null
) / nullif(count(*), 0),
1
) as "Без_ФИАС_процент",
count(*) filter (
where coalesce(nullif(btrim(full_address), ''), nullif(btrim(original_address), '')) is not null
) as "Объектов_с_адресом",
round(
100.0 * count(*) filter (
where coalesce(nullif(btrim(full_address), ''), nullif(btrim(original_address), '')) is not null
) / nullif(count(*), 0),
1
) as "Адрес_процент",
count(*) filter (
where nullif(btrim(characteristics ->> 'total_area_sq_m'), '') is not null
) as "Объектов_с_площадью",
round(
100.0 * count(*) filter (
where nullif(btrim(characteristics ->> 'total_area_sq_m'), '') is not null
) / nullif(count(*), 0),
1
) as "Площадь_процент",
count(*) filter (
where latitude is not null and longitude is not null
) as "Объектов_с_координатами",
round(
100.0 * count(*) filter (
where latitude is not null and longitude is not null
) / nullif(count(*), 0),
1
) as "Координаты_процент",
count(*) filter (
where nullif(btrim(address_dgis_id), '') is not null
) as "Объектов_с_ID_2ГИС",
count(*) filter (
where nullif(btrim(fias_code), '') is not null
and nullif(btrim(characteristics ->> 'total_area_sq_m'), '') is not null
and nullif(btrim(object_description), '') is not null
) as "Кандидатов_ЕГРН_по_ФИАС_площади_типу",
count(*) filter (
where coalesce(nullif(btrim(full_address), ''), nullif(btrim(original_address), '')) is not null
and nullif(btrim(characteristics ->> 'total_area_sq_m'), '') is not null
and nullif(btrim(object_description), '') is not null
) as "Кандидатов_ЕГРН_по_адресу_площади_типу",
count(*) filter (
where nullif(btrim(fias_code), '') is null
and not (
coalesce(nullif(btrim(full_address), ''), nullif(btrim(original_address), '')) is not null
and nullif(btrim(characteristics ->> 'total_area_sq_m'), '') is not null
and nullif(btrim(object_description), '') is not null
)
) as "Без_рабочего_ключа_для_ЕГРН"
from display_rows;
