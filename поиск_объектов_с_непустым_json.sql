with recent_tasks as (
    select
        t.id,
        t.request_ins_id,
        t.d_create
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

ranked_objects as (
    select
        t.d_create as task_create_date,
        r.contract_id,
        obj.id as object_id,
        obj.description,
        geo.full_address,
        op.characteristics,

        row_number() over (
            partition by obj.id
            order by
                t.d_create desc,
                op.id desc
        ) as object_row_number

    from recent_tasks t

    join bps_request_ins r
        on r.id = t.request_ins_id

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
      and op.characteristics is not null
      and op.characteristics <> '{}'::jsonb
      and op.characteristics <> '[]'::jsonb
      and op.characteristics <> 'null'::jsonb
)

select
    obj.contract_id
        as "ID договора",

    obj.object_id
        as "ID объекта",

    obj.description
        as "Описание объекта",

    obj.full_address
        as "Нормализованный адрес",

    jsonb_typeof(obj.characteristics)
        as "Тип JSON",

    json_keys.key_names
        as "Названия полей JSON",

    obj.characteristics
        as "Характеристики JSONB"

from ranked_objects obj

left join lateral (
    select
        string_agg(json_key, ', ' order by json_key) as key_names
    from jsonb_object_keys(
        case
            when jsonb_typeof(obj.characteristics) = 'object'
                then obj.characteristics
            else '{}'::jsonb
        end
    ) as json_key
) as json_keys
    on true

where obj.object_row_number = 1

order by obj.task_create_date desc

limit 20;
