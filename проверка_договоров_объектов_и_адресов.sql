select
    r.contract_id
        as "ID договора",

    c.n_contract
        as "Номер договора",

    c.document_status
        as "Статус договора",

    t.id
        as "ID задачи",

    obj.id
        as "ID объекта",

    obj.obj_name
        as "Название объекта",

    obj.original_address
        as "Адрес как его ввели",

    geo.full_address
        as "Нормализованный адрес",

    op.insurance_value
        as "Страховая стоимость",

    op.is_pledged
        as "Есть залог",

    op.pledged_value
        as "Залоговая стоимость",

    bcc.industry
        as "Отрасль из CRM",

    t.industry
        as "Отрасль из задачи",

    r.is_underwriter_involvement_required
        as "Требуется андеррайтер",

    t.tariff_calculation
        as "Вариант расчета тарифа",

    t.is_receipts_calculator_received
        as "Получен расчет калькулятора"

from bps_request_ins_task t

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

left join bps_corporate_crm bcc
    on bcc.id = r.corporate_crm_id

where t.task_type = 'draft_contract'
  and t.status = 'operational_archive'
  and r.contract_id is not null
  and (
      t.ins_document_type = 'new_ins_contract'
      or t.ins_document_type = 'ins_contract_prolong'
      or t.ins_document_type is null
  )
  and obj.elementary_obj_type in (
      'nedv_ul_and_ip',
      'business_interruption'
  )

order by
    t.d_create desc,
    r.contract_id,
    geo.full_address,
    obj.id

limit 20;
