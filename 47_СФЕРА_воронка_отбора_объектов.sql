/*
запускать в сфере

запрос показывает сколько договоров и объектов остается после каждого шага
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
    select *
    from task_candidates
    where task_number = 1
),

object_links as (
    /* добавляем связи с объектами */
    select
        task.contract_id,
        task.task_id,
        link.id as link_id,
        link.characteristics_id,
        link.d_create as link_create_date,
        link.d_change as link_change_date
    from selected_tasks task
    join bps_request_ins_task_insurance_object link
        on link.parent_id = task.task_id
),

objects_with_characteristics as (
    /* добавляем характеристики */
    select
        link.*,
        ch.insurance_object_id as object_id,
        ch.version_start_date,
        ch.version_number
    from object_links link
    join base_insurance_object_characteristics ch
        on ch.id = link.characteristics_id
),

resolved_objects as (
    /* добавляем объекты */
    select
        data.*,
        obj.elementary_obj_type,
        obj.d_delete as object_delete_date
    from objects_with_characteristics data
    join base_insurance_object obj
        on obj.id = data.object_id
),

live_objects as (
    /* убираем удаленные объекты */
    select *
    from resolved_objects
    where object_delete_date is null
),

real_estate_objects as (
    /* оставляем недвижимость */
    select *
    from live_objects
    where elementary_obj_type = 'nedv_ul_and_ip'
),

ranked_objects as (
    /* выбираем последнюю связь с объектом */
    select
        data.*,
        row_number() over (
            partition by data.task_id, data.object_id
            order by
                data.link_change_date desc nulls last,
                data.link_create_date desc nulls last,
                data.version_start_date desc nulls last,
                data.version_number desc nulls last,
                data.link_id desc,
                data.characteristics_id desc
        ) as object_number
    from real_estate_objects data
),

final_objects as (
    select *
    from ranked_objects
    where object_number = 1
),

funnel as (
    select
        1 as step_number,
        'Подходящие задачи' as step_name,
        count(*) as row_count,
        count(distinct contract_id) as contract_count,
        count(distinct task_id) as task_count,
        null::bigint as object_count
    from task_candidates

    union all

    select
        2,
        'Оставлена последняя задача договора',
        count(*),
        count(distinct contract_id),
        count(distinct task_id),
        null::bigint
    from selected_tasks

    union all

    select
        3,
        'Найдена связь задачи с объектом',
        count(*),
        count(distinct contract_id),
        count(distinct task_id),
        null::bigint
    from object_links

    union all

    select
        4,
        'Найдены характеристики объекта',
        count(*),
        count(distinct contract_id),
        count(distinct task_id),
        count(distinct object_id)
    from objects_with_characteristics

    union all

    select
        5,
        'Найден объект в base_insurance_object',
        count(*),
        count(distinct contract_id),
        count(distinct task_id),
        count(distinct object_id)
    from resolved_objects

    union all

    select
        6,
        'Объект не удалён',
        count(*),
        count(distinct contract_id),
        count(distinct task_id),
        count(distinct object_id)
    from live_objects

    union all

    select
        7,
        'Оставлена недвижимость nedv_ul_and_ip',
        count(*),
        count(distinct contract_id),
        count(distinct task_id),
        count(distinct object_id)
    from real_estate_objects

    union all

    select
        8,
        'Итог: одна актуальная строка на объект в договоре',
        count(*),
        count(distinct contract_id),
        count(distinct task_id),
        count(distinct object_id)
    from final_objects
)

select
    step_number as "Шаг",
    step_name as "Что осталось",
    row_count as "Строк",
    contract_count as "Договоров",
    task_count as "Задач",
    object_count as "Уникальных object_id"
from funnel
order by step_number;
