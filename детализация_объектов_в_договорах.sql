with recent_tasks as (
    select
        t.id,
        t.request_ins_id
    from bps_request_ins_task t
    where t.task_type = 'draft_contract'
      and t.status = 'operational_archive'
      and (
          t.ins_document_type = 'new_ins_contract'
          or t.ins_document_type = 'ins_contract_prolong'
          or t.ins_document_type is null
      )
    order by t.d_create desc
    limit 1000
),

object_rows as (
    select distinct
        r.contract_id,
        c.n_contract,
        obj.id as object_id,
        obj.obj_name,
        obj.obj_type,
        obj.elementary_obj_type,
        obj.original_address,
        geo.full_address

    from recent_tasks t

    join bps_request_ins r
        on r.id = t.request_ins_id

    left join bps_contract c
        on c.id = r.contract_id

    join bps_request_ins_task_insurance_object tobj
        on tobj.parent_id = t.id

    join base_insurance_object_characteristics op
        on op.id = tobj.characteristics_id

    join base_insurance_object obj
        on obj.id = op.insurance_object_id

    left join base_geo_address geo
        on geo.id = obj.geo_address_id

    where r.contract_id is not null
      and obj.elementary_obj_type in (
          'nedv_ul_and_ip',
          'business_interruption'
      )
),

multi_object_contracts as (
    select
        contract_id,
        count(distinct object_id) as object_count

    from object_rows

    group by contract_id

    having count(distinct object_id) > 1
),

numbered_contracts as (
    select
        contract_id,
        object_count,

        row_number() over (
            order by object_count desc, contract_id
        ) as contract_number

    from multi_object_contracts
)

select
    nc.contract_number
        as "Условный номер договора",

    obj.contract_id
        as "ID договора",

    obj.n_contract
        as "Номер договора",

    nc.object_count
        as "Всего объектов в договоре",

    obj.object_id
        as "ID объекта",

    obj.obj_name
        as "Название объекта",

    obj.obj_type
        as "Тип объекта",

    obj.elementary_obj_type
        as "Подтип объекта",

    obj.original_address
        as "Адрес как его ввели",

    obj.full_address
        as "Нормализованный адрес"

from numbered_contracts nc

join object_rows obj
    on obj.contract_id = nc.contract_id

where nc.contract_number <= 20

order by
    nc.contract_number,
    obj.full_address nulls last,
    obj.object_id;
