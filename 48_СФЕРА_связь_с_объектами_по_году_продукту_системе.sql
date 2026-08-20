/*
запускать в сфере

запрос показывает заполненность связей с объектами
по году продукту и системе источнику
*/

with task_candidates as (
    /* отбираем нужные задачи */
    select
        c.id as contract_id,
        c.d_start_contract as contract_start_date,
        c.system_type as source_system,
        c.ins_product_sbs as contract_product,
        r.ins_product as request_product,
        t.ins_product as task_product,
        t.id as task_id,
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

contract_profile as (
    /* проверяем связи и типы объектов */
    select
        task.contract_id,
        task.contract_start_date,
        task.source_system,
        task.contract_product,
        task.request_product,
        task.task_product,
        count(link.id) > 0 as has_object_link,
        count(obj.id) filter (
            where obj.elementary_obj_type = 'nedv_ul_and_ip'
              and obj.d_delete is null
        ) > 0 as has_real_estate
    from selected_tasks task
    left join bps_request_ins_task_insurance_object link
        on link.parent_id = task.task_id
    left join base_insurance_object_characteristics ch
        on ch.id = link.characteristics_id
    left join base_insurance_object obj
        on obj.id = ch.insurance_object_id
    group by
        task.contract_id,
        task.contract_start_date,
        task.source_system,
        task.contract_product,
        task.request_product,
        task.task_product
),

report_rows as (
    /* собираем разрезы в одну таблицу */
    select
        profile.contract_id,
        profile.has_object_link,
        profile.has_real_estate,
        report.report_name,
        report.report_value
    from contract_profile profile
    cross join lateral (
        values
        (
            'год начала договора',
            coalesce(
                extract(year from profile.contract_start_date)::text,
                '[не заполнено]'
            )
        ),
        (
            'продукт из договора',
            coalesce(
                nullif(btrim(profile.contract_product), ''),
                '[не заполнено]'
            )
        ),
        (
            'продукт из заявки',
            coalesce(
                nullif(btrim(profile.request_product), ''),
                '[не заполнено]'
            )
        ),
        (
            'продукт из задачи',
            coalesce(
                nullif(btrim(profile.task_product), ''),
                '[не заполнено]'
            )
        ),
        (
            'система источник',
            coalesce(
                nullif(btrim(profile.source_system), ''),
                '[не заполнено]'
            )
        )
    ) as report(report_name, report_value)
)

select
    report_name as "Разрез",
    report_value as "Значение",
    count(*) as "Договоров",
    count(*) filter (
        where has_object_link
    ) as "Договоров со связью на объект",
    count(*) filter (
        where has_real_estate
    ) as "Договоров с недвижимостью",
    round(
        100.0 * count(*) filter (
            where has_object_link
        ) / nullif(count(*), 0),
        1
    ) as "Связь на объект процентов",
    round(
        100.0 * count(*) filter (
            where has_real_estate
        ) / nullif(count(*), 0),
        1
    ) as "Недвижимость процентов"
from report_rows
group by
    report_name,
    report_value
order by
    report_name,
    "Договоров" desc,
    report_value;
