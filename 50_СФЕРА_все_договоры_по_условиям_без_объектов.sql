/*
запускать в сфере

одна строка результата соответствует одному договору
объекты адреса и данные клиента не присоединяются
*/

with contract_tasks as (
    /* отбираем нужные задачи */
    select
        c.id as contract_id,
        c.n_contract as contract_number,
        c.document_status as contract_status,
        c.d_sign_contract as contract_sign_date,
        c.d_start_contract as contract_start_date,
        c.d_end_contract as contract_end_date,
        c.system_type as source_system,
        c.ins_product_sbs as contract_product,

        r.id as request_id,
        r.ins_product as request_product,

        t.id as task_id,
        t.d_create as task_create_date,
        t.d_change as task_change_date,
        t.d_conclusion_ins_contract as contract_conclusion_date,
        t.task_type,
        t.status as task_status,
        t.ins_document_type,
        t.ins_product as task_product,
        t.ins_refuse,

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
)

select
    contract_id as "ID договора",
    contract_number as "Номер договора",
    contract_status as "Статус договора",
    contract_sign_date as "Дата подписания",
    contract_start_date as "Дата начала",
    contract_end_date as "Дата окончания",
    source_system as "Система источник",
    contract_product as "Продукт из договора",
    request_id as "ID заявки",
    request_product as "Продукт из заявки",
    task_id as "ID задачи",
    task_create_date as "Дата создания задачи",
    task_change_date as "Дата изменения задачи",
    contract_conclusion_date as "Дата заключения",
    task_type as "Тип задачи",
    task_status as "Статус задачи",
    ins_document_type as "Тип документа",
    task_product as "Продукт из задачи",
    ins_refuse as "Отказ в страховании"
from contract_tasks
where task_number = 1
order by
    contract_start_date desc nulls last,
    contract_id;
