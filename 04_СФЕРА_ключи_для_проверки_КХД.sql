/*
ЗАПУСКАТЬ В ПОДКЛЮЧЕНИИ К БАЗЕ "СФЕРА".

В файле четыре независимых запроса.
Запускать по одному: от WITH до ближайшей точки с запятой.

Запрос 1 возвращает только агрегаты и показывает, какими ключами можно
связать 486 договоров со справочником договоров КХД.

Запрос 2 возвращает по одной строке на договор. Результат конфиденциальный:
не отправлять в Git и не пересылать за пределы рабочей среды.

Запрос 3 возвращает по одной строке на объект недвижимости в выбранной
задаче договора. Ожидаемый порядок величины — 1051 строка.

Запрос 4 создаёт готовый Oracle-запрос только для наших подходящих
договоров. Результатом будет одна длинная ячейка с SQL-кодом. Её нужно
скопировать в редактор подключения КХД 1.0 и выполнить там.
*/


/* ======================================================================
ЗАПРОС 1 ИЗ 4. ЗАПОЛНЕННОСТЬ КЛЮЧЕЙ ДЛЯ СВЯЗИ С КХД
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
ЗАПРОС 2 ИЗ 4. ОДНА СТРОКА НА ДОГОВОР ДЛЯ СВЕРКИ С КХД

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
ЗАПРОС 3 ИЗ 4. ОДНА СТРОКА НА ОБЪЕКТ НЕДВИЖИМОСТИ

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


/* ======================================================================
ЗАПРОС 4 ИЗ 4. СОЗДАТЬ ORACLE-ЗАПРОС ДЛЯ НАШИХ ДОГОВОРОВ

Что сделать:
1. Выполнить этот запрос в "Сфере".
2. В результате получится одна ячейка "Готовый Oracle запрос".
3. Скопировать содержимое этой ячейки целиком.
4. Вставить в редактор подключения КХД 1.0 и выполнить.

Договорные идентификаторы останутся только на рабочем компьютере.
====================================================================== */

with task_candidates as (
select
c.id as contract_id,
c.n_contract,
c.n_contract_cleaned,
c.sbs_id,
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
),
oracle_rows as (
select
contract_id,
'select '
|| quote_nullable(contract_id::text)
|| ' as sphere_contract_id, '
|| quote_nullable(nullif(btrim(sbs_id), ''))
|| ' as sphere_sbs_id, '
|| quote_nullable(nullif(btrim(n_contract), ''))
|| ' as sphere_policy_number, '
|| quote_nullable(nullif(btrim(n_contract_cleaned), ''))
|| ' as sphere_policy_number_cleaned from dual'
as oracle_row
from population
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
contract_matches as (
select
s.sphere_contract_id,
s.sphere_sbs_id,
s.sphere_policy_number,
s.sphere_policy_number_cleaned,
d.policy_id as khd_policy_id,
d.policy_number as khd_policy_number,
d.product_group as khd_product_group,
d.object_type as khd_object_type,
d.cadaster as khd_cadaster,
case
when s.sphere_sbs_id is not null
and trim(d.policy_id) = trim(s.sphere_sbs_id)
then 1 else 0
end as matched_by_id,
case
when (
s.sphere_policy_number is not null
and upper(trim(d.policy_number)) = upper(trim(s.sphere_policy_number))
)
or (
s.sphere_policy_number_cleaned is not null
and upper(trim(d.policy_number)) =
upper(trim(s.sphere_policy_number_cleaned))
)
then 1 else 0
end as matched_by_number,
case
when d.policy_number_normalized is not null
and (
(
s.sphere_policy_number is not null
and d.policy_number_normalized = regexp_replace(
upper(trim(s.sphere_policy_number)),
'[^[:alnum:]]',
''
)
)
or (
s.sphere_policy_number_cleaned is not null
and d.policy_number_normalized = regexp_replace(
upper(trim(s.sphere_policy_number_cleaned)),
'[^[:alnum:]]',
''
)
)
)
then 1 else 0
end as matched_by_normalized_number
from sphere_contracts s
left join (
select
policy_id,
policy_number,
product_group,
object_type,
cadaster,
regexp_replace(
upper(trim(policy_number)),
'[^[:alnum:]]',
''
) as policy_number_normalized
from dm_risk_avatar.dict_ins_potential_object_address_extra
) d
on (
s.sphere_sbs_id is not null
and trim(d.policy_id) = trim(s.sphere_sbs_id)
)
or (
s.sphere_policy_number is not null
and upper(trim(d.policy_number)) = upper(trim(s.sphere_policy_number))
)
or (
s.sphere_policy_number_cleaned is not null
and upper(trim(d.policy_number)) =
upper(trim(s.sphere_policy_number_cleaned))
)
or (
d.policy_number_normalized is not null
and s.sphere_policy_number is not null
and d.policy_number_normalized = regexp_replace(
upper(trim(s.sphere_policy_number)),
'[^[:alnum:]]',
''
)
)
or (
d.policy_number_normalized is not null
and s.sphere_policy_number_cleaned is not null
and d.policy_number_normalized = regexp_replace(
upper(trim(s.sphere_policy_number_cleaned)),
'[^[:alnum:]]',
''
)
)
)
select
count(distinct m.sphere_contract_id)
as "Договоров Сферы в проверке",
count(distinct case
when m.matched_by_id = 1 then m.sphere_contract_id
end) as "Найдено по ID договора",
count(distinct case
when m.matched_by_number = 1 then m.sphere_contract_id
end) as "Найдено по номеру договора",
count(distinct case
when m.matched_by_normalized_number = 1 then m.sphere_contract_id
end) as "Найдено по очищенному номеру",
count(distinct case
when m.matched_by_id = 1
or m.matched_by_number = 1
or m.matched_by_normalized_number = 1
then m.sphere_contract_id
end) as "Договоров найдено в DICT",
count(distinct case
when trim(m.khd_cadaster) is not null then m.sphere_contract_id
end) as "Договоров с кадастровым номером",
count(distinct case
when e.cadaster is not null then m.sphere_contract_id
end) as "Договоров найдено в EGRN_DATA",
count(distinct case
when trim(m.khd_cadaster) is not null then m.khd_cadaster
end) as "Кадастровых номеров из DICT",
count(distinct e.cadaster)
as "Кадастровых номеров найдено в EGRN_DATA",
round(
100 * count(distinct case
when e.cadaster is not null then m.sphere_contract_id
end) / nullif(count(distinct m.sphere_contract_id), 0),
1
) as "Доля договоров с найденным ЕГРН процентов"
from contract_matches m
left join dm_risk_avatar.egrn_data e
on trim(e.cadaster) = trim(m.khd_cadaster)
$oracle$
as "Готовый Oracle запрос"
from oracle_rows;
