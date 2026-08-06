/*
ЗАПУСКАТЬ В DBeaver В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Цель:
показать уникальные значения полей, которые используются в WHERE объектной
выборки, количество строк для каждого значения и входит ли значение в текущий
отбор.

Важно:
- количество считается отдельно для каждой колонки, поэтому числа между
  разными колонками складывать нельзя;
- типы объектов считаются только внутри задач, прошедших текущие условия по
  задаче;
- запрос ничего не изменяет в базе.
*/

with task_scope as (
select
t.id as task_id,
t.task_type,
t.status,
t.ins_document_type,
t.ins_refuse,
t.d_delete
from bps_request_ins_task t
join bps_request_ins r
on r.id = t.request_ins_id
join bps_contract c
on c.id = r.contract_id
where r.d_delete is null
and c.d_delete is null
),

task_values as (
select
1 as stage_order,
'До применения условий по задаче'::text as stage_name,
'bps_request_ins_task'::text as table_name,
value.column_name,
value.column_value,
count(*) as row_count,
case
when value.column_name = 'task_type'
and value.column_value = 'draft_contract' then 'YES'
when value.column_name = 'status'
and value.column_value = 'operational_archive' then 'YES'
when value.column_name = 'ins_document_type'
and value.column_value in (
'new_ins_contract',
'ins_contract_prolong',
'[NULL]'
) then 'YES'
when value.column_name = 'ins_refuse'
and value.column_value in ('false', '[NULL]') then 'YES'
when value.column_name = 'record_state'
and value.column_value = 'NOT_DELETED' then 'YES'
else 'NO'
end as used_in_current_where
from task_scope task
cross join lateral (
values
('task_type', coalesce(task.task_type::text, '[NULL]')),
('status', coalesce(task.status::text, '[NULL]')),
('ins_document_type', coalesce(task.ins_document_type::text, '[NULL]')),
('ins_refuse', coalesce(task.ins_refuse::text, '[NULL]')),
(
'record_state',
case
when task.d_delete is null then 'NOT_DELETED'
else 'DELETED'
end
)
) as value(column_name, column_value)
group by
value.column_name,
value.column_value
),

filtered_tasks as (
select task_id
from task_scope
where task_type = 'draft_contract'
and status = 'operational_archive'
and (
ins_document_type = 'new_ins_contract'
or ins_document_type = 'ins_contract_prolong'
or ins_document_type is null
)
and ins_refuse is not true
and d_delete is null
),

object_scope as (
select distinct
task.task_id,
obj.id as object_id,
obj.elementary_obj_type,
case
when obj.d_delete is null then 'NOT_DELETED'
else 'DELETED'
end as object_record_state
from filtered_tasks task
join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = task.task_id
join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
join base_insurance_object obj
on obj.id = ch.insurance_object_id
),

object_values as (
select
2 as stage_order,
'После применения условий по задаче'::text as stage_name,
'base_insurance_object'::text as table_name,
value.column_name,
value.column_value,
count(*) as row_count,
case
when value.column_name = 'elementary_obj_type'
and value.column_value = 'nedv_ul_and_ip' then 'YES'
when value.column_name = 'record_state'
and value.column_value = 'NOT_DELETED' then 'YES'
else 'NO'
end as used_in_current_where
from object_scope object_row
cross join lateral (
values
(
'elementary_obj_type',
coalesce(object_row.elementary_obj_type::text, '[NULL]')
),
('record_state', object_row.object_record_state)
) as value(column_name, column_value)
group by
value.column_name,
value.column_value
)

select
stage_name as "Этап",
table_name as "Таблица",
column_name as "Колонка из WHERE",
column_value as "Уникальное значение",
row_count as "Количество строк",
used_in_current_where as "Используется в текущем отборе"
from (
select * from task_values
union all
select * from object_values
) result
order by
stage_order,
table_name,
column_name,
used_in_current_where desc,
row_count desc,
column_value;
