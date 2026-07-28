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
)

select
    r.contract_id
        as "ID договора",

    c.n_contract
        as "Номер договора",

    count(distinct obj.id)
        as "Количество объектов",

    count(
        distinct nullif(
            btrim(obj.original_address),
            ''
        )
    )
        as "Адресов как ввели",

    count(
        distinct nullif(
            btrim(geo.full_address),
            ''
        )
    )
        as "Нормализованных адресов",

    count(distinct obj.id) filter (
        where nullif(btrim(obj.original_address), '') is null
    )
        as "Объектов без введенного адреса",

    count(distinct obj.id) filter (
        where nullif(btrim(geo.full_address), '') is null
    )
        as "Объектов без нормализованного адреса"

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

group by
    r.contract_id,
    c.n_contract

having count(distinct obj.id) > 1

order by
    count(distinct obj.id) desc

limit 20;
