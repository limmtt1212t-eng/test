/*
Запускать в DBeaver в подключении к «Сфере».

Что показывает запрос
---------------------
Одна строка результата — один объект недвижимости в последней подходящей
задаче конкретного договора.

Условия отбора
--------------
1. Тип задачи: draft_contract — оформление договора.
2. Статус задачи: operational_archive — этот статус использован в переданном
   запросе как признак завершённого оформления. Его бизнес-смысл ещё нужно
   подтвердить у владельца данных.
3. Тип документа: новый договор, пролонгация или незаполненное значение.
4. Отказ не установлен.
5. Удалённые задача, заявка и договор исключены.
6. Тип объекта: nedv_ul_and_ip — недвижимость юридических лиц и ИП.
7. Если у договора несколько подходящих задач, берётся самая поздняя.
8. Если один объект несколько раз добавлен в выбранную задачу, берётся
   последняя запись связи с последней версией характеристик.

Как читать суммы
----------------
- СС договора — общая страховая сумма из выбранной задачи оформления.
- СС объекта из связи — значение, записанное непосредственно при добавлении
  объекта в задачу.
- Минимальная и максимальная СС объекта — диапазон значений из всех вариантов
  условий страхования выбранной версии объекта.
- Минимальная и максимальная СС среди объектов договора — диапазон объектных
  сумм из условий внутри выбранной задачи договора. Это НЕ исторический
  минимум и максимум общей суммы договора.
- Площадь берётся из total_area_sq_m внутри JSON-характеристик объекта.
  Выводится исходное значение без дополнительного пересчёта.
*/

with task_candidates as (
    select
        t.id as task_id,
        r.id as request_id,
        r.contract_id,
        row_number() over (
            partition by r.contract_id
            order by
                t.d_conclusion_ins_contract desc nulls last,
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
    select
        task_id,
        request_id,
        contract_id
    from task_candidates
    where task_number = 1
),

object_candidates as (
    select
        c.id as contract_id,
        c.n_contract as contract_number,
        c.document_status as contract_status,
        c.d_start_contract as contract_start_date,
        c.d_end_contract as contract_end_date,
        c.contractor_id as policyholder_id,
        policyholder.inn as policyholder_inn,
        policyholder.cdi_id as policyholder_cdi_id,
        r.id as request_id,
        r.corporate_crm_id,
        t.id as task_id,
        t.task_type,
        t.status as task_status,
        t.ins_document_type,
        t.ins_refuse,
        t.total_ins_contract_amount as contract_insured_sum,
        t.curr_ins_contract_amount as contract_insured_sum_currency,
        link.id as task_object_link_id,
        link.characteristics_id,
        link.insured_sum as task_object_insured_sum,
        link.insured_sum_currency as task_object_insured_sum_currency,
        obj.id as object_id,
        obj.elementary_obj_type,
        obj.obj_name as object_name,
        obj.description as object_description,
        nullif(
            btrim(ch.characteristics ->> 'total_area_sq_m'),
            ''
        ) as object_area,
        obj.original_address,
        obj.geo_address_id,
        geo.full_address,
        geo.fias_code,
        geo.address_dgis_id,
        row_number() over (
            partition by t.id, obj.id
            order by
                link.d_change desc nulls last,
                link.d_create desc nulls last,
                ch.version_start_date desc nulls last,
                ch.version_number desc nulls last,
                link.id desc,
                ch.id desc
        ) as object_number
    from selected_tasks selected
    join bps_request_ins_task t
        on t.id = selected.task_id
    join bps_request_ins r
        on r.id = selected.request_id
    join bps_contract c
        on c.id = selected.contract_id
    join bps_request_ins_task_insurance_object link
        on link.parent_id = t.id
    join base_insurance_object_characteristics ch
        on ch.id = link.characteristics_id
    join base_insurance_object obj
        on obj.id = ch.insurance_object_id
    left join base_geo_address geo
        on geo.id = obj.geo_address_id
    left join bps_contractor policyholder
        on policyholder.id = c.contractor_id
    where obj.elementary_obj_type = 'nedv_ul_and_ip'
),

selected_objects as (
    select
        contract_id,
        contract_number,
        contract_status,
        contract_start_date,
        contract_end_date,
        policyholder_id,
        policyholder_inn,
        policyholder_cdi_id,
        request_id,
        corporate_crm_id,
        task_id,
        task_type,
        task_status,
        ins_document_type,
        ins_refuse,
        contract_insured_sum,
        contract_insured_sum_currency,
        task_object_link_id,
        characteristics_id,
        task_object_insured_sum,
        task_object_insured_sum_currency,
        object_id,
        elementary_obj_type,
        object_name,
        object_description,
        object_area,
        original_address,
        geo_address_id,
        full_address,
        fias_code,
        address_dgis_id
    from object_candidates
    where object_number = 1
),

condition_sums as (
    select
        condition.characteristics_id,
        min(condition.insured_sum) as minimum_object_insured_sum,
        max(condition.insured_sum) as maximum_object_insured_sum,
        string_agg(
            distinct condition.insured_sum_currency,
            ', '
            order by condition.insured_sum_currency
        ) filter (
            where condition.insured_sum_currency is not null
        ) as condition_currencies
    from base_insurance_object_conditions condition
    group by condition.characteristics_id
),

objects_with_sums as (
    select
        obj.*,
        conditions.minimum_object_insured_sum,
        conditions.maximum_object_insured_sum,
        conditions.condition_currencies
    from selected_objects obj
    left join condition_sums conditions
        on conditions.characteristics_id = obj.characteristics_id
)

select
    obj.contract_id as "ID договора",
    obj.contract_number as "Номер договора",
    obj.contract_status as "Статус договора",
    obj.contract_start_date as "Дата начала договора",
    obj.contract_end_date as "Дата окончания договора",

    obj.contract_insured_sum as "СС по договору",
    obj.contract_insured_sum_currency as "Валюта СС по договору",
    min(obj.minimum_object_insured_sum) over (
        partition by obj.contract_id
    ) as "Мин. СС среди объектов договора",
    max(obj.maximum_object_insured_sum) over (
        partition by obj.contract_id
    ) as "Макс. СС среди объектов договора",

    obj.object_id as "ID объекта",
    obj.object_name as "Название объекта",
    obj.object_description as "Описание объекта",
    obj.object_area as "Площадь объекта из характеристик",
    obj.elementary_obj_type as "Тип объекта",
    obj.task_object_insured_sum as "СС объекта из связи с задачей",
    obj.task_object_insured_sum_currency
        as "Валюта СС объекта из связи",
    obj.minimum_object_insured_sum as "Мин. СС объекта из условий",
    obj.maximum_object_insured_sum as "Макс. СС объекта из условий",
    obj.condition_currencies as "Валюты СС объекта из условий",
    obj.full_address as "Полный адрес",
    obj.original_address as "Адрес как ввели",
    obj.fias_code as "ФИАС объекта",
    obj.address_dgis_id as "ID адреса 2ГИС",

    obj.policyholder_id as "ID страхователя",
    obj.policyholder_inn as "ИНН страхователя",
    obj.policyholder_cdi_id as "ID страхователя в CDI",
    obj.corporate_crm_id as "ID CRM-карточки",
    obj.request_id as "ID заявки",
    obj.task_id as "ID задачи",
    obj.task_object_link_id as "ID связи задачи и объекта",
    obj.characteristics_id as "ID характеристик объекта",
    obj.geo_address_id as "ID адреса",

    obj.task_type as "Условие: тип задачи",
    obj.task_status as "Условие: статус задачи",
    obj.ins_document_type as "Условие: тип документа",
    obj.ins_refuse as "Условие: установлен отказ"
from objects_with_sums obj
order by
    obj.contract_id,
    obj.object_id;

/*
Подводные камни
---------------
1. operational_archive — статус задачи, а не доказательство юридической
   действительности договора. Поэтому статус договора выведен отдельно.
2. СС объекта хранится в двух местах. В связи задачи с объектом она часто
   пустая, а в условиях одного объекта может быть несколько значений.
3. Минимум и максимум из условий показывают диапазон, но не выбирают
   автоматически правильную целевую СС.
4. СС договора повторяется в каждой строке объекта одного договора.
   Складывать её по строкам нельзя.
5. Сумма объектных СС не обязана равняться общей СС договора.
6. Сравнивать суммы можно только с учётом валюты. Если внутри одного договора
   объектные суммы записаны в разных валютах, минимум и максимум по договору
   нельзя интерпретировать без пересчёта в одну валюту.
7. Один полный адрес может относиться к нескольким зданиям или помещениям.
   Адрес не является ID объекта и не подходит для автоматического склеивания.
8. Описание помогает различать объекты по одному адресу, но также не является
   уникальным ключом.
9. Площадь хранится внутри JSON и может быть пустой или записанной текстом.
10. Полный адрес может быть пустым. Тогда остаётся адрес, введённый вручную.
11. Запрос берёт только последнюю подходящую задачу договора. Это текущий
    объектный срез, а не полная история всех изменений договора.
*/
