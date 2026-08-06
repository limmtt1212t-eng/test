/*
ЗАПУСКАТЬ В DBeaver В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Цель:
соединить рабочую объектную выборку недвижимости ЮЛ с корпоративными убытками.

Единица результата:
одна строка = один убыток и один возможный объект этого убытка.

Почему возможный объект:
убыток напрямую связан с договором или задачей, но не всегда содержит ID
конкретного объекта страхования. Если в договоре несколько объектов, запрос
сравнивает адрес убытка с адресом объекта и показывает качество связи.

Качество связи:
HIGH_ADDRESS_MATCH     — адрес подошёл только к одному объекту;
MEDIUM_SINGLE_OBJECT   — в договоре только один возможный объект;
AMBIGUOUS_SAME_ADDRESS — один адрес подошёл к нескольким объектам;
AMBIGUOUS_CONTRACT_ONLY — известен договор, но конкретный объект не определён.

Для демонстрации оставлен LIMIT 200. Для полной выгрузки удалить только
последнюю строку "limit 200".

Запрос ничего не изменяет в базе.
*/

with task_candidates as (
select
c.id as contract_id,
c.n_contract,
c.contractor_id,
r.corporate_crm_id,
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
select
contract_id,
n_contract,
contractor_id,
corporate_crm_id,
task_id,
as_of_date
from task_candidates
where task_rank = 1
),

object_candidates as (
select
task.contract_id,
task.n_contract,
task.contractor_id,
task.corporate_crm_id,
task.task_id,
task.as_of_date,
policyholder.inn as policyholder_inn,
policyholder.company_name_short as policyholder_name,
crm.industry as crm_industry,
crm.macroindustry as crm_macroindustry,
crm.okved as crm_okved,
obj.id as object_id,
obj.description as object_description,
obj.obj_type,
obj.elementary_obj_type,
obj.original_address,
geo.full_address,
geo.latitude,
geo.longitude,
geo.address_dgis_id,
ch.insurance_value,
ch.insurance_value_currency,
ch.is_pledged,
ch.pledged_value,
ch.characteristics ->> 'total_area_sq_m' as sphere_total_area_sq_m,
tobj.insured_sum as object_insured_sum,
tobj.insured_sum_currency as object_insured_sum_currency,
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
left join bps_contractor policyholder
on policyholder.id = task.contractor_id
left join bps_corporate_crm crm
on crm.id = task.corporate_crm_id
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
),

object_address_source as (
select
object_row.*,
coalesce(
nullif(btrim(object_row.full_address), ''),
nullif(btrim(object_row.original_address), '')
) as object_address,
count(*) over (
partition by object_row.contract_id
) as objects_in_contract
from one_row_per_object object_row
),

object_address_normalized as (
select
object_address_source.*,
btrim(
regexp_replace(
regexp_replace(
regexp_replace(
regexp_replace(
lower(
replace(
replace(coalesce(object_address, ''), chr(160), ' '),
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
) as object_address_lower
from object_address_source
),

object_prepared as (
select
object_address_normalized.*,
coalesce(
(regexp_match(object_address_lower, '(?:^|, )(?:г|город) ([^,]+)(?:,|$)'))[1],
(regexp_match(object_address_lower, '(?:^|, )(?:пгт|поселок городского типа|рп|рабочий поселок|пос|поселок|с|село|д|деревня) ([^,]+)(?:,|$)'))[1],
(regexp_match(object_address_lower, '(?:^|, )([^,]+), (?:[^,]+ (?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея)|(?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея) [^,]+)(?:,|$)'))[1]
) as object_locality,
coalesce(
(regexp_match(object_address_lower, '(?:^|, )(?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея) ([^,]+)(?:,|$)'))[1],
(regexp_match(object_address_lower, '(?:^|, )([^,]+?) (?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея)(?:,|$)'))[1]
) as object_street,
coalesce(
(regexp_match(object_address_lower, '(?:^|, )(?:д|дом) *([0-9]+[а-яa-z]?(?:[/-][0-9а-яa-z]+)?)(?:,|$)'))[1],
(regexp_match(object_address_lower, '(?:^|, )([0-9]+[а-яa-z]?(?:[/-][0-9а-яa-z]+)?)$'))[1]
) as object_house,
btrim(
regexp_replace(
object_address_lower,
'[^0-9a-zа-я]+',
' ',
'g'
)
) as object_full_address_key
from object_address_normalized
),

claim_source as (
select
cl.*,
applicant.inn as applicant_inn,
applicant.company_name_short as applicant_name,
coalesce(
nullif(btrim(cl.obj_address), ''),
nullif(btrim(cl.fias_address), ''),
nullif(btrim(cl.place_ins_event), '')
) as claim_address
from bps_corporate_claim cl
left join bps_contractor applicant
on applicant.id = cl.appliant_id
where cl.d_delete is null
),

claim_prepared as (
select
claim_source.*,
nullif(
btrim(
regexp_replace(
replace(lower(coalesce(city_ins_event, '')), 'ё', 'е'),
'^(г|город|пгт|рп|п|пос|поселок|с|село|д|деревня)[.]?[[:space:]]+',
'',
'g'
)
),
''
) as claim_locality,
nullif(
btrim(
regexp_replace(
replace(lower(coalesce(street_ins_event, '')), 'ё', 'е'),
'(^|[[:space:]])(ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея)([[:space:]]|$)',
' ',
'g'
)
),
''
) as claim_street,
nullif(
regexp_replace(
replace(lower(coalesce(house_ins_event, '')), 'ё', 'е'),
'[^0-9а-яa-z/-]+',
'',
'g'
),
''
) as claim_house,
btrim(
regexp_replace(
regexp_replace(
lower(
replace(
replace(coalesce(claim_address, ''), chr(160), ' '),
'ё',
'е'
)
),
'[^0-9a-zа-я]+',
' ',
'g'
),
'[[:space:]]+',
' ',
'g'
)
) as claim_full_address_key
from claim_source
),

loss_object_candidates as (
select
object_row.*,
claim.id as loss_id,
claim.d_create as loss_create_date,
claim.n_loss,
claim.contract_id as loss_contract_id,
claim.request_ins_tasks_id as loss_task_id,
claim.appliant_id,
claim.applicant_inn,
claim.applicant_name,
claim.claim_address,
claim.claim_locality,
claim.claim_street,
claim.claim_house,
claim.d_case as event_date,
claim.d_case_fact as event_date_fact,
claim.d_claim as application_date,
claim.d_decision as decision_date,
claim.d_close as close_date,
claim.risk as declared_risk,
claim.loss_risk,
claim.ins_event_type,
claim.insured_event,
claim.decision,
claim.claim_cancel_reason,
claim.loss_sum,
claim.s_claim_curr_expense,
claim.s_claim_curr_contract,
claim.rzu_with_franchise_rub,
claim.s_reject,
claim.loss_currency,
case
when claim.request_ins_tasks_id = object_row.task_id
and claim.contract_id = object_row.contract_id then 'TASK_ID_AND_CONTRACT_ID'
when claim.request_ins_tasks_id = object_row.task_id then 'TASK_ID'
when claim.contract_id = object_row.contract_id then 'CONTRACT_ID'
else 'UNKNOWN'
end as contract_link_method,
case
when object_row.object_full_address_key <> ''
and claim.claim_full_address_key <> ''
and object_row.object_full_address_key = claim.claim_full_address_key then true
when object_row.object_locality is not null
and object_row.object_street is not null
and object_row.object_house is not null
and claim.claim_locality is not null
and claim.claim_street is not null
and claim.claim_house is not null
and object_row.object_locality = claim.claim_locality
and object_row.object_street = claim.claim_street
and object_row.object_house = claim.claim_house then true
else false
end as object_address_matches_claim
from object_prepared object_row
join claim_prepared claim
on claim.contract_id = object_row.contract_id
or claim.request_ins_tasks_id = object_row.task_id
),

candidate_quality as (
select
candidate.*,
count(*) over (
partition by candidate.loss_id
) as candidate_objects_for_loss,
count(*) filter (
where candidate.object_address_matches_claim
) over (
partition by candidate.loss_id
) as address_matched_objects_for_loss
from loss_object_candidates candidate
),

final_rows as (
select
quality.*,
case
when object_address_matches_claim
and address_matched_objects_for_loss = 1 then 'HIGH_ADDRESS_MATCH'
when candidate_objects_for_loss = 1 then 'MEDIUM_SINGLE_OBJECT'
when object_address_matches_claim
and address_matched_objects_for_loss > 1 then 'AMBIGUOUS_SAME_ADDRESS'
else 'AMBIGUOUS_CONTRACT_ONLY'
end as object_loss_link_quality
from candidate_quality quality
)

select
contract_id,
n_contract,
task_id,
policyholder_inn,
policyholder_name,
crm_industry,
crm_macroindustry,
crm_okved,
object_id,
object_description,
obj_type,
elementary_obj_type,
object_address,
object_locality,
object_street,
object_house,
latitude,
longitude,
address_dgis_id,
sphere_total_area_sq_m,
insurance_value,
insurance_value_currency,
is_pledged,
pledged_value,
object_insured_sum,
object_insured_sum_currency,
objects_in_contract,
loss_id,
n_loss,
loss_create_date,
event_date,
event_date_fact,
application_date,
decision_date,
close_date,
declared_risk,
loss_risk,
ins_event_type,
insured_event,
decision,
claim_cancel_reason,
loss_sum,
s_claim_curr_expense,
s_claim_curr_contract,
rzu_with_franchise_rub,
s_reject,
loss_currency,
appliant_id,
applicant_inn,
applicant_name,
claim_address,
claim_locality,
claim_street,
claim_house,
contract_link_method,
object_address_matches_claim,
candidate_objects_for_loss,
address_matched_objects_for_loss,
object_loss_link_quality
from final_rows
order by
loss_create_date desc nulls last,
loss_id,
object_id
limit 200;
