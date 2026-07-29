with task_candidates as (
select
c.id
as contract_id,
c.n_contract,
c.n_contract_cleaned,
c.contractor_id,
c.rootcontract_id,
c.prevcontract_id,
c.currency
as contract_currency,
c.active
as contract_record_active,
c.status
as contract_status,
c.document_status,
c.document_state,
c.d_sign_contract,
c.d_start_contract,
c.d_end_contract,
c.d_active_contract,
c.d_termination,
c.ins_product_sbs,
c.ins_program,
r.id
as request_id,
r.d_create
as request_create_date,
r.corporate_crm_id,
r.business_segment,
r.sale_channel
as request_sale_channel,
r.comment_object_type,
r.is_underwriter_involvement_required,
t.id
as task_id,
t.d_create
as task_create_date,
t.d_change
as task_change_date,
t.status
as task_status,
t.result
as task_result,
t.ins_document_type,
t.d_conclusion_ins_contract,
t.ins_refuse,
t.task_annul_reason,
t.task_cancel_reason,
t.industry
as task_industry,
t.subindustry
as task_subindustry,
t.tariff_calculation,
t.is_receipts_calculator_received,
t.undewriter_method,
t.total_ins_contract_amount,
t.total_ins_contract_premium,
t.curr_ins_contract_amount,
coalesce(
t.d_conclusion_ins_contract::timestamp with time zone,
c.d_sign_contract,
t.d_create
)
as as_of_date,
count(*) over (
partition by c.id
)
as candidate_task_count,
row_number() over (
partition by c.id
order by
t.d_conclusion_ins_contract desc nulls last,
t.d_create desc nulls last,
t.d_change desc nulls last,
t.id desc
)
as task_rank
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
selected_task_per_contract as (
select *
from task_candidates
where task_rank = 1
),
property_tasks as (
select task.*
from selected_task_per_contract task
where exists (
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
as_of_date desc nulls last,
contract_id desc
limit 200
),
task_context as (
select
task.*,
policyholder.inn
as policyholder_inn,
nullif(
regexp_replace(
coalesce(policyholder.inn, ''),
'[^0-9]',
'',
'g'
),
''
)
as normalized_policyholder_inn,
policyholder.ogrn
as policyholder_ogrn,
policyholder.kpp
as policyholder_kpp,
policyholder.company_name_short
as policyholder_name,
policyholder.company_form
as policyholder_company_form,
policyholder.company_register_day
as policyholder_register_date,
crm.id
as crm_id,
crm.client_id
as crm_client_id,
crm.segment
as crm_segment,
crm.macroindustry
as crm_macroindustry,
crm.industry
as crm_industry,
crm.primary_occupation
as crm_primary_occupation,
crm.specialization
as crm_specialization,
crm.okved
as crm_okved,
(
crm.client_id is not null
and crm.client_id = task.contractor_id
)
as crm_client_is_policyholder
from sampled_tasks task
left join bps_contractor policyholder
on policyholder.id = task.contractor_id
left join bps_corporate_crm crm
on crm.id = task.corporate_crm_id
),
object_link_candidates as (
select
context.*,
tobj.id
as task_object_link_id,
tobj.characteristics_id,
tobj.d_create
as task_object_link_create_date,
tobj.d_change
as task_object_link_change_date,
tobj.object_group_id,
tobj.insured_sum
as task_object_insured_sum,
tobj.insured_sum_currency
as task_object_insured_sum_currency,
tobj.per_occurance_limit
as task_object_per_occurrence_limit,
obj.id
as insurance_object_id,
obj.obj_name,
obj.description
as object_description,
obj.obj_type,
obj.elementary_obj_type,
obj.original_address,
obj.geo_address_id,
obj.address_validation_code,
obj.is_address_validated_by_user,
obj.active
as object_record_active,
ch.version_number
as characteristics_version_number,
ch.version_start_date
as characteristics_version_start,
ch.version_end_date
as characteristics_version_end,
ch.version_is_active
as characteristics_version_is_active,
ch.insurance_value,
ch.insurance_value_currency,
ch.insurance_value_basis,
ch.is_pledged,
ch.pledged_value,
ch.pledgee_inn,
ch.ownership_type,
ch.is_leased,
ch.lessor_inn,
ch.insured_components,
ch.activity_types,
ch.risk_natures,
ch.insurance_territory,
ch.region
as characteristics_region,
ch.has_losses,
ch.insurance_object_loss_history,
ch.characteristics,
case
when ch.characteristics is null
then false
when ch.characteristics = '{}'::jsonb
then false
when ch.characteristics = '[]'::jsonb
then false
when ch.characteristics = 'null'::jsonb
then false
else true
end
as characteristics_json_is_filled,
ch.characteristics ->> 'total_area_sq_m'
as json_total_area_sq_m,
ch.characteristics ->> 'occupied_area_sq_m'
as json_occupied_area_sq_m,
ch.characteristics ->> 'construction_year'
as json_construction_year,
ch.characteristics ->> 'last_capital_repair_year'
as json_last_capital_repair_year,
ch.characteristics ->> 'total_floors_count'
as json_total_floors_count,
ch.characteristics ->> 'occupied_floor'
as json_occupied_floor,
ch.characteristics ->> 'load_bearing_walls_material'
as json_load_bearing_walls_material,
ch.characteristics ->> 'columns_material'
as json_columns_material,
ch.characteristics ->> 'interfloor_overlap_material'
as json_interfloor_overlap_material,
ch.characteristics ->> 'partitions_material'
as json_partitions_material,
ch.characteristics ->> 'roofing_material'
as json_roofing_material,
ch.characteristics ->> 'facade_insulation_material'
as json_facade_insulation_material,
ch.characteristics ->> 'internal_insulation_material'
as json_internal_insulation_material,
count(*) over (
partition by context.task_id, obj.id
)
as object_link_count_in_selected_task,
row_number() over (
partition by context.task_id, obj.id
order by
tobj.d_change desc nulls last,
tobj.d_create desc nulls last,
ch.version_start_date desc nulls last,
ch.version_number desc nulls last,
tobj.id desc,
ch.id desc
)
as object_row_number
from task_context context
join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = context.task_id
join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
join base_insurance_object obj
on obj.id = ch.insurance_object_id
where obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
),
one_row_per_object as (
select *
from object_link_candidates
where object_row_number = 1
),
selected_characteristics as (
select distinct
characteristics_id
from one_row_per_object
),
condition_summary as (
select
condition.characteristics_id,
count(*)
as condition_row_count,
min(condition.insured_sum)
as condition_min_insured_sum,
max(condition.insured_sum)
as condition_max_insured_sum,
min(condition.per_occurance_limit)
as condition_min_per_occurrence_limit,
max(condition.per_occurance_limit)
as condition_max_per_occurrence_limit,
jsonb_agg(
jsonb_strip_nulls(
jsonb_build_object(
'condition_id', condition.id,
'terms_option_number', condition.terms_option_number,
'insured_sum', condition.insured_sum,
'insured_sum_currency', condition.insured_sum_currency,
'per_occurrence_limit', condition.per_occurance_limit
)
)
order by
condition.terms_option_number nulls last,
condition.id
)
as conditions_json
from base_insurance_object_conditions condition
join selected_characteristics selected
on selected.characteristics_id = condition.characteristics_id
group by
condition.characteristics_id
),
object_occurrence_summary as (
select
insurance_object_id,
count(distinct contract_id)
as contracts_for_object_in_selected_slice
from one_row_per_object
group by
insurance_object_id
)
select
object_row.contract_id,
object_row.n_contract,
object_row.as_of_date,
count(*) over (
partition by object_row.contract_id
)
as objects_in_contract,
row_number() over (
partition by object_row.contract_id
order by object_row.insurance_object_id
)
as object_number_in_contract,
object_row.insurance_object_id,
object_row.object_description,
object_row.obj_name,
object_row.obj_type,
object_row.elementary_obj_type,
address.full_address
as normalized_address,
object_row.original_address,
address.fias_code,
concat_ws(
':',
object_row.task_id::text,
object_row.insurance_object_id::text
)
as object_exposure_key,
'sfera'
as source_system,
current_timestamp
as extracted_at,
object_row.task_object_link_id,
object_row.characteristics_id,
object_row.geo_address_id,
object_row.task_id,
object_row.request_id,
object_row.contractor_id,
occurrence.contracts_for_object_in_selected_slice,
object_row.candidate_task_count,
object_row.object_link_count_in_selected_task,
object_row.n_contract_cleaned,
object_row.rootcontract_id,
object_row.prevcontract_id,
object_row.contract_record_active,
object_row.contract_status,
object_row.document_status,
object_row.document_state,
object_row.d_sign_contract,
object_row.d_start_contract,
object_row.d_end_contract,
object_row.d_active_contract,
object_row.d_termination,
object_row.contract_currency,
object_row.ins_product_sbs,
object_row.ins_program,
object_row.request_create_date,
object_row.business_segment,
object_row.request_sale_channel,
object_row.comment_object_type,
object_row.task_create_date,
object_row.task_change_date,
object_row.task_status,
object_row.task_result,
object_row.ins_document_type,
object_row.d_conclusion_ins_contract,
object_row.ins_refuse,
object_row.task_annul_reason,
object_row.task_cancel_reason,
object_row.is_underwriter_involvement_required,
object_row.tariff_calculation,
object_row.is_receipts_calculator_received,
object_row.undewriter_method,
object_row.policyholder_inn,
object_row.normalized_policyholder_inn,
object_row.policyholder_ogrn,
object_row.policyholder_kpp,
object_row.policyholder_name,
object_row.policyholder_company_form,
object_row.policyholder_register_date,
object_row.crm_id,
object_row.crm_client_id,
object_row.crm_client_is_policyholder,
object_row.crm_segment,
object_row.crm_macroindustry,
object_row.crm_industry,
object_row.crm_primary_occupation,
object_row.crm_specialization,
object_row.crm_okved,
object_row.task_industry,
object_row.task_subindustry,
object_row.object_group_id,
object_row.object_record_active,
address.postal_code,
address.region_id
as address_region_id,
address.area_type,
address.area,
address.settlement_type,
address.settlement,
address.street_type,
address.street,
address.house,
address.building,
address.block,
address.flat,
address.office,
address.longitude,
address.latitude,
address.address_dgis_id,
object_row.address_validation_code,
object_row.is_address_validated_by_user,
object_row.characteristics_version_number,
object_row.characteristics_version_start,
object_row.characteristics_version_end,
object_row.characteristics_version_is_active,
object_row.insurance_value,
object_row.insurance_value_currency,
object_row.insurance_value_basis,
object_row.is_pledged,
object_row.pledged_value,
object_row.pledgee_inn,
object_row.ownership_type,
object_row.is_leased,
object_row.lessor_inn,
object_row.task_object_insured_sum,
object_row.task_object_insured_sum_currency,
object_row.task_object_per_occurrence_limit,
conditions.condition_row_count,
conditions.condition_min_insured_sum,
conditions.condition_max_insured_sum,
conditions.condition_min_per_occurrence_limit,
conditions.condition_max_per_occurrence_limit,
conditions.conditions_json,
object_row.total_ins_contract_amount,
object_row.total_ins_contract_premium,
object_row.curr_ins_contract_amount,
object_row.insured_components,
object_row.activity_types,
object_row.risk_natures,
object_row.insurance_territory,
object_row.characteristics_region,
object_row.has_losses,
object_row.insurance_object_loss_history,
object_row.characteristics_json_is_filled,
object_row.json_total_area_sq_m,
object_row.json_occupied_area_sq_m,
object_row.json_construction_year,
object_row.json_last_capital_repair_year,
object_row.json_total_floors_count,
object_row.json_occupied_floor,
object_row.json_load_bearing_walls_material,
object_row.json_columns_material,
object_row.json_interfloor_overlap_material,
object_row.json_partitions_material,
object_row.json_roofing_material,
object_row.json_facade_insulation_material,
object_row.json_internal_insulation_material,
object_row.characteristics
from one_row_per_object object_row
left join base_geo_address address
on address.id = object_row.geo_address_id
left join condition_summary conditions
on conditions.characteristics_id = object_row.characteristics_id
left join object_occurrence_summary occurrence
on occurrence.insurance_object_id = object_row.insurance_object_id
order by
object_row.as_of_date desc nulls last,
object_row.contract_id,
object_row.insurance_object_id;
