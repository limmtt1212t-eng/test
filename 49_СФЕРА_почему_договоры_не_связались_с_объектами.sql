/*
запускать в сфере

запрос проверяет есть ли связь с объектом
в других задачах того же договора
*/

with task_candidates as (
    /* отбираем нужные задачи */
    select
        c.id as contract_id,
        t.id as task_id,
        t.d_conclusion_ins_contract,
        t.d_create,
        t.d_change,
        row_number() over (
            partition by c.id
            order by
                coalesce(
                    t.d_conclusion_ins_contract::timestamp with time zone,
                    t.d_create,
                    t.d_change
                ) desc nulls last,
                t.d_create desc nulls last,
                t.d_change desc nulls last,
                t.id desc
        ) as task_number
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
    /* оставляем последнюю задачу договора */
    select
        contract_id,
        task_id
    from task_candidates
    where task_number = 1
),

linked_tasks as (
    /* собираем все задачи договора со связью на объект */
    select distinct
        request_all.contract_id,
        task_all.id as task_id,
        request_all.d_delete is null
        and task_all.d_delete is null as is_live
    from selected_tasks selected
    join bps_request_ins request_all
        on request_all.contract_id = selected.contract_id
    join bps_request_ins_task task_all
        on task_all.request_ins_id = request_all.id
    join bps_request_ins_task_insurance_object link
        on link.parent_id = task_all.id
),

link_profile as (
    /* сравниваем выбранную задачу с другими задачами договора */
    select
        selected.contract_id,
        coalesce(
            bool_or(linked.task_id = selected.task_id),
            false
        ) as link_in_selected_task,
        coalesce(
            bool_or(
                linked.task_id <> selected.task_id
                and suitable.task_id is not null
            ),
            false
        ) as link_in_other_suitable_task,
        coalesce(
            bool_or(
                linked.task_id <> selected.task_id
                and linked.is_live
            ),
            false
        ) as link_in_other_live_task,
        coalesce(
            bool_or(linked.task_id <> selected.task_id),
            false
        ) as link_in_any_other_task
    from selected_tasks selected
    left join linked_tasks linked
        on linked.contract_id = selected.contract_id
    left join task_candidates suitable
        on suitable.contract_id = linked.contract_id
       and suitable.task_id = linked.task_id
    group by selected.contract_id
),

reasons as (
    /* определяем где нашлась связь */
    select
        contract_id,
        case
            when link_in_selected_task
                then '1 связь есть в выбранной задаче'
            when link_in_other_suitable_task
                then '2 связь есть в другой подходящей задаче'
            when link_in_other_live_task
                then '3 связь есть в другой неудаленной задаче'
            when link_in_any_other_task
                then '4 связь есть только в удаленной задаче или заявке'
            else '5 связи нет ни в одной задаче договора'
        end as reason
    from link_profile
)

select
    reason as "Результат проверки",
    count(*) as "Договоров",
    round(
        100.0 * count(*) / sum(count(*)) over (),
        1
    ) as "Доля процентов"
from reasons
group by reason
order by reason;
