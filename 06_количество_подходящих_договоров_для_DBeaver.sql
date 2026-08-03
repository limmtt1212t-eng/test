/*
МОДЕЛЬ 1. СКОЛЬКО ДОГОВОРОВ ПОДХОДИТ ПОД ТЕКУЩЕЕ ТЕХНИЧЕСКОЕ ПРАВИЛО

Результат — одна строка с тремя числами:
1. Все неудалённые записи договоров.
2. Договоры, у которых есть подходящая задача оформления.
3. Договоры, у которых в выбранной задаче есть недвижимость ЮЛ.

Текущее правило подходящей задачи:
- тип задачи draft_contract;
- статус задачи operational_archive;
- новый договор, пролонгация или незаполненный тип документа;
- отказ не установлен в TRUE;
- задача, заявка и договор не удалены;
- если у договора несколько таких задач, выбирается одна наиболее поздняя;
- в выбранной задаче должен быть объект nedv_ul_and_ip.

Важно: это техническое правило исследовательской выборки.
Оно пока не доказывает, что договор юридически заключён.
*/

with all_contracts as (
select
c.id as contract_id
from bps_contract c
where c.d_delete is null
),
task_candidates as (
select
c.id as contract_id,
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
selected_task_per_contract as (
select
contract_id,
task_id
from task_candidates
where task_rank = 1
),
eligible_contracts as (
select
task.contract_id
from selected_task_per_contract task
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
(select count(*) from all_contracts)
as "Всего_неудалённых_записей_договоров",
(select count(distinct contract_id) from task_candidates)
as "Договоров_с_подходящей_задачей",
(select count(*) from eligible_contracts)
as "Подходящих_договоров_с_недвижимостью",
round(
100.0 * (select count(*) from eligible_contracts)
/ nullif((select count(*) from all_contracts), 0),
1
)
as "Доля_подходящих_процентов";
