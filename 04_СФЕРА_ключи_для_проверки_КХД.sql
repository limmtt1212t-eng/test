/*
ЗАПУСКАТЬ В ПОДКЛЮЧЕНИИ К БАЗЕ "СФЕРА".

В файле три независимых запроса.
Запускать по одному: от WITH до ближайшей точки с запятой.

Запрос 1 возвращает только агрегаты и показывает, какими ключами можно
связать 486 договоров со справочником договоров КХД.

Запрос 2 возвращает по одной строке на договор. Результат конфиденциальный:
не отправлять в Git и не пересылать за пределы рабочей среды.

Запрос 3 возвращает по одной строке на объект недвижимости в выбранной
задаче договора. Ожидаемый порядок величины — 1051 строка.
*/


/* ======================================================================
ЗАПРОС 1 ИЗ 3. ЗАПОЛНЕННОСТЬ КЛЮЧЕЙ ДЛЯ СВЯЗИ С КХД
====================================================================== */

with task_candidates as (
select
c.id as contract_id,
c.n_contract,
c.n_contract_cleaned,
c.sbs_id,
c.core_id,
c.system_type,
c.d_sign_contract,
c.d_start_contract,
c.d_end_contract,
c.contractor_id,
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
select
task.*,
regexp_replace(
coalesce(policyholder.inn, ''),
'[^0-9]',
'',
'g'
) as inn_digits
from selected_tasks task
left join bps_contractor policyholder
on policyholder.id = task.contractor_id
where exists (
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
)
select
count(*) as "Договоров с недвижимостью",
count(*) filter (
where nullif(btrim(sbs_id), '') is not null
) as "Есть sbs_id",
count(distinct nullif(btrim(sbs_id), ''))
as "Уникальных sbs_id",
count(*) filter (
where nullif(btrim(core_id), '') is not null
) as "Есть core_id",
count(*) filter (
where nullif(btrim(n_contract), '') is not null
) as "Есть номер договора",
count(distinct nullif(btrim(n_contract), ''))
as "Уникальных номеров договора",
count(*) filter (
where nullif(btrim(n_contract_cleaned), '') is not null
) as "Есть очищенный номер договора",
count(distinct nullif(btrim(n_contract_cleaned), ''))
as "Уникальных очищенных номеров",
count(*) filter (
where length(inn_digits) in (10, 12)
) as "Есть ИНН длины 10 или 12",
count(*) filter (
where d_sign_contract is not null
) as "Есть дата подписания",
count(*) filter (
where d_start_contract is not null
) as "Есть дата начала",
count(*) filter (
where nullif(btrim(n_contract), '') is not null
and length(inn_digits) in (10, 12)
and coalesce(d_sign_contract, d_start_contract) is not null
) as "Есть номер плюс ИНН плюс дата"
from population;


/* ======================================================================
ЗАПРОС 2 ИЗ 3. ОДНА СТРОКА НА ДОГОВОР ДЛЯ СВЕРКИ С КХД

Сначала попробуйте связать:
Сфера.sbs_id = КХД.CONTRACTS.CONTRACT_ID.

Если sbs_id не заполнен или не находится, используйте одновременно:
номер договора + ИНН + дата.
====================================================================== */

with task_candidates as (
select
c.id as contract_id,
c.n_contract,
c.n_contract_cleaned,
c.sbs_id,
c.core_id,
c.system_type,
c.d_sign_contract,
c.d_start_contract,
c.d_end_contract,
c.contractor_id,
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
object_counts as (
select
task.contract_id,
count(distinct obj.id) as real_estate_object_count
from selected_tasks task
join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = task.task_id
join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
join base_insurance_object obj
on obj.id = ch.insurance_object_id
where obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
group by task.contract_id
)
select
task.contract_id as "Сфера contract_id",
task.sbs_id as "Сфера sbs_id кандидат CONTRACT_ID КХД",
task.core_id as "Сфера core_id",
task.n_contract as "Номер договора",
task.n_contract_cleaned as "Очищенный номер договора",
regexp_replace(
coalesce(policyholder.inn, ''),
'[^0-9]',
'',
'g'
) as "ИНН",
task.d_sign_contract::date as "Дата подписания",
task.d_start_contract::date as "Дата начала",
task.d_end_contract::date as "Дата окончания",
task.system_type as "Система источник",
task.task_id as "ID выбранной задачи",
objects.real_estate_object_count as "Объектов недвижимости"
from selected_tasks task
join object_counts objects
on objects.contract_id = task.contract_id
left join bps_contractor policyholder
on policyholder.id = task.contractor_id
order by
task.d_start_contract desc nulls last,
task.contract_id;


/* ======================================================================
ЗАПРОС 3 ИЗ 3. ОДНА СТРОКА НА ОБЪЕКТ НЕДВИЖИМОСТИ

Эта выгрузка понадобится после того, как договорная связь с КХД будет
подтверждена. Адрес и характеристики используются для контроля совпадения.
====================================================================== */

with task_candidates as (
select
c.id as contract_id,
c.n_contract,
c.n_contract_cleaned,
c.sbs_id,
c.core_id,
c.d_sign_contract,
c.d_start_contract,
c.contractor_id,
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
object_candidates as (
select
task.contract_id,
task.sbs_id,
task.core_id,
task.n_contract,
task.n_contract_cleaned,
task.d_sign_contract,
task.d_start_contract,
task.task_id,
tobj.id as task_object_link_id,
ch.id as characteristics_id,
obj.id as object_id,
obj.description as object_description,
obj.geo_address_id,
geo.full_address,
geo.latitude,
geo.longitude,
ch.characteristics ->> 'total_area_sq_m' as area_from_json,
ch.characteristics ->> 'construction_year' as construction_year_from_json,
ch.characteristics ->> 'load_bearing_walls_material'
as wall_material_from_json,
regexp_replace(
coalesce(policyholder.inn, ''),
'[^0-9]',
'',
'g'
) as inn_digits,
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
left join bps_contractor policyholder
on policyholder.id = task.contractor_id
where obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
)
select
contract_id as "Сфера contract_id",
sbs_id as "Сфера sbs_id кандидат CONTRACT_ID КХД",
core_id as "Сфера core_id",
n_contract as "Номер договора",
n_contract_cleaned as "Очищенный номер договора",
inn_digits as "ИНН",
d_sign_contract::date as "Дата подписания",
d_start_contract::date as "Дата начала",
task_id as "ID выбранной задачи",
task_object_link_id as "ID связи задача объект",
characteristics_id as "ID характеристик",
object_id as "Сфера object_id",
object_description as "Описание объекта",
geo_address_id as "Сфера geo_address_id",
full_address as "Адрес Сферы",
latitude as "Широта Сферы",
longitude as "Долгота Сферы",
area_from_json as "Площадь Сферы из JSON",
construction_year_from_json as "Год постройки Сферы из JSON",
wall_material_from_json as "Материал стен Сферы из JSON"
from object_candidates
where object_rank = 1
order by
d_start_contract desc nulls last,
contract_id,
object_id;

