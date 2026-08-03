/*
ИССЛЕДОВАНИЕ ПЕРЕХОДА 15 622 ДОГОВОРОВ -> 483 ДОГОВОРА

Запрос не выгружает сведения о клиентах и объектах.
Он возвращает одну строку только с количествами.

Главный вопрос:
недвижимость отсутствует во всех подходящих задачах договора
или она есть, но пропадает после выбора только последней задачи?
*/

with task_candidates as (
select
c.id as contract_id,
t.id as task_id,
t.d_conclusion_ins_contract,
t.d_create as task_create_date,
t.d_change as task_change_date
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
ranked_tasks as (
select
task_candidates.*,
row_number() over (
partition by contract_id
order by
d_conclusion_ins_contract desc nulls last,
task_create_date desc nulls last,
task_change_date desc nulls last,
task_id desc
) as task_rank
from task_candidates
),
task_object_profile as (
select
task.contract_id,
task.task_id,
task.task_rank,
count(distinct tobj.id) as object_link_count,
count(distinct ch.id) as characteristics_count,
count(distinct obj.id) filter (
where obj.id is not null
) as resolved_object_count,
count(distinct obj.id) filter (
where obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
) as real_estate_object_count
from ranked_tasks task
left join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = task.task_id
left join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
left join base_insurance_object obj
on obj.id = ch.insurance_object_id
group by
task.contract_id,
task.task_id,
task.task_rank
),
contract_profile as (
select
contract_id,
count(*) as candidate_task_count,
bool_or(object_link_count > 0) as has_link_in_any_task,
bool_or(characteristics_count > 0) as has_characteristics_in_any_task,
bool_or(resolved_object_count > 0) as has_object_in_any_task,
bool_or(real_estate_object_count > 0) as has_real_estate_in_any_task,
bool_or(task_rank = 1 and object_link_count > 0) as has_link_in_selected_task,
bool_or(task_rank = 1 and characteristics_count > 0) as has_characteristics_in_selected_task,
bool_or(task_rank = 1 and resolved_object_count > 0) as has_object_in_selected_task,
bool_or(task_rank = 1 and real_estate_object_count > 0) as has_real_estate_in_selected_task
from task_object_profile
group by contract_id
)
select
sum(candidate_task_count)
as "Строк_подходящих_задач",
count(*)
as "Договоров_с_подходящей_задачей",
count(*) filter (
where has_link_in_any_task
)
as "Договоров_со_связью_задача_объект_в_любой_задаче",
count(*) filter (
where has_characteristics_in_any_task
)
as "Договоров_с_характеристиками_в_любой_задаче",
count(*) filter (
where has_object_in_any_task
)
as "Договоров_с_найденным_объектом_в_любой_задаче",
count(*) filter (
where has_real_estate_in_any_task
)
as "Договоров_с_недвижимостью_в_любой_задаче",
count(*) filter (
where has_link_in_selected_task
)
as "Договоров_со_связью_задача_объект_в_последней_задаче",
count(*) filter (
where has_characteristics_in_selected_task
)
as "Договоров_с_характеристиками_в_последней_задаче",
count(*) filter (
where has_object_in_selected_task
)
as "Договоров_с_найденным_объектом_в_последней_задаче",
count(*) filter (
where has_real_estate_in_selected_task
)
as "Договоров_с_недвижимостью_в_последней_задаче",
count(*) filter (
where has_real_estate_in_any_task
and not has_real_estate_in_selected_task
)
as "Потеряно_из_за_выбора_последней_задачи",
round(
100.0 * count(*) filter (
where has_real_estate_in_any_task
)
/ nullif(count(*), 0),
2
)
as "Недвижимость_в_любой_задаче_процентов",
round(
100.0 * count(*) filter (
where has_real_estate_in_selected_task
)
/ nullif(count(*), 0),
2
)
as "Недвижимость_в_последней_задаче_процентов"
from contract_profile;
