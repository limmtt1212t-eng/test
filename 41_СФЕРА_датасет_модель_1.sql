/*
Для чего нужен запрос
---------------------
Запрос собирает основу датасета для модели 1 по недвижимости ЮЛ.
Он объединяет сведения о договоре, объекте, адресе, страхователе,
отрасли, страховых суммах и ближайшем предыдущем договоре.

Одна строка результата
----------------------
Одна строка - один объект недвижимости в одном договоре.
Один договор может занимать несколько строк, если в нем несколько объектов.


Как связаны таблицы
-------------------
Договор -> заявка -> задача оформления -> объект в задаче
        -> характеристики объекта -> сам объект -> адрес
        -> условия страхования объекта

Из договора берется страхователь. Из заявки берется CRM-карточка,
в которой находятся отрасль и сегмент.

Какие записи попадают в результат
---------------------------------
- задача оформления договора: task_type = draft_contract;
- завершенная рабочая задача: status = operational_archive;
- тип документа: ins_document_type = new_ins_contract,
  ins_contract_prolong или NULL, то есть новый договор, пролонгация
  или незаполненное значение;
- отказ в страховании не установлен: ins_refuse IS NOT TRUE;
- дата удаления отсутствует: d_delete IS NULL для задачи, заявки,
  договора и объекта;
- тип объекта: elementary_obj_type = nedv_ul_and_ip,
  то есть недвижимость ЮЛ и ИП.


Как читать страховые суммы
--------------------------
- contract_insured_sum - общая СС всего договора;
- task_object_insured_sum - СС объекта в строке связи задачи и объекта;
- condition_min_insured_sum и condition_max_insured_sum - минимальная и
  максимальная СС среди условий выбранной версии объекта;
- insured_sum - СС среди условий выбранной версии объекта.


Как используется история
-------------------------
Ближайший предыдущий договор ищется по bps_contract.prevcontract_id.
Прошлая СС объекта заполняется только тогда, когда в текущем и предыдущем
договоре совпал object_id. Если при пролонгации объект завели с новым ID,
прошлая объектная СС останется пустой.

*/

with task_candidates as (
    /* Шаг 1. Находим все подходящие задачи оформления. */
    select
        c.id as contract_id,
        c.n_contract as contract_number,
        c.prevcontract_id as previous_contract_id,
        c.rootcontract_id as root_contract_id,
        c.contractor_id as policyholder_id,
        c.document_status as contract_status,
        c.d_sign_contract as contract_sign_date,
        c.d_start_contract as contract_start_date,
        c.d_end_contract as contract_end_date,
        c.currency as contract_currency,
        c.ins_product_sbs as insurance_product,
        c.ins_program as insurance_program,

        r.id as request_id,
        r.corporate_crm_id,
        r.business_segment,

        t.id as task_id,
        t.d_create as task_create_date,
        t.d_change as task_change_date,
        t.task_type,
        t.status as task_status,
        t.ins_document_type,
        t.contract_type,
        t.d_conclusion_ins_contract as contract_conclusion_date,
        t.ins_refuse,
        t.industry as task_industry,
        t.subindustry as task_subindustry,
        t.total_ins_contract_amount as contract_insured_sum,
        t.total_ins_contract_premium as contract_premium,
        t.curr_ins_contract_amount as contract_amount_currency,

        coalesce(
            t.d_conclusion_ins_contract::timestamp with time zone,
            c.d_sign_contract,
            t.d_create
        ) as as_of_date,

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
    /* Шаг 2. Для каждого договора оставляем одну самую позднюю задачу. */
    select *
    from task_candidates
    where task_number = 1
),

contract_context as (
    /* Шаг 3. Добавляем ближайший предыдущий договор, если он указан. */
    select
        current_task.*,
        previous_contract.n_contract as previous_contract_number,
        previous_contract.d_start_contract as previous_contract_start_date,
        previous_contract.d_end_contract as previous_contract_end_date,
        previous_task.contract_insured_sum as previous_contract_insured_sum,
        previous_task.contract_premium as previous_contract_premium,
        previous_task.contract_amount_currency
            as previous_contract_amount_currency
    from selected_tasks current_task
    left join bps_contract previous_contract
        on previous_contract.id = current_task.previous_contract_id
    left join selected_tasks previous_task
        on previous_task.contract_id = current_task.previous_contract_id
),

object_candidates as (
    /*
    Шаг 4. К выбранной задаче присоединяем объекты недвижимости.
    Здесь же добавляем адрес, страхователя, CRM и характеристики объекта.
    */
    select
        contract.*,

        policyholder.inn as policyholder_inn,
        policyholder.contractor_type as policyholder_type,
        policyholder.cdi_id as policyholder_cdi_id,
        policyholder.ogrn as policyholder_ogrn,
        policyholder.kpp as policyholder_kpp,
        policyholder.company_name_short as policyholder_name,
        policyholder.company_form as policyholder_company_form,
        policyholder.company_register_day
            as policyholder_registration_date,

        crm.id as crm_id,
        crm.client_id as crm_client_id,
        crm.segment as crm_segment,
        crm.macroindustry as crm_macroindustry,
        crm.industry as crm_industry,
        crm.primary_occupation as crm_primary_occupation,
        crm.specialization as crm_specialization,
        crm.okved as crm_okved,

        link.id as task_object_link_id,
        link.characteristics_id,
        link.object_group_id,
        link.insured_sum as task_object_insured_sum,
        link.insured_sum_currency as task_object_insured_sum_currency,
        link.per_occurance_limit as task_object_per_occurrence_limit,

        obj.id as object_id,
        obj.obj_name as object_name,
        obj.description as object_description,
        obj.obj_type as object_type,
        obj.elementary_obj_type,
        obj.original_address,
        obj.geo_address_id,

        ch.version_number as characteristics_version_number,
        ch.version_start_date as characteristics_version_start_date,
        ch.version_end_date as characteristics_version_end_date,
        ch.version_is_active as characteristics_version_is_active,
        ch.insurance_value,
        ch.insurance_value_currency,
        ch.insurance_value_basis,
        ch.is_pledged,
        ch.pledged_value,
        ch.ownership_type,
        ch.is_leased,
        ch.insured_components,
        ch.activity_types,
        ch.risk_natures,
        ch.insurance_territory,
        ch.characteristics ->> 'total_area_sq_m' as total_area,
        ch.characteristics ->> 'occupied_area_sq_m' as occupied_area,
        ch.characteristics ->> 'construction_year' as construction_year,
        ch.characteristics ->> 'last_capital_repair_year'
            as capital_repair_year,
        ch.characteristics ->> 'total_floors_count' as floors_count,
        ch.characteristics ->> 'occupied_floor' as occupied_floor,
        ch.characteristics ->> 'load_bearing_walls_material'
            as walls_material,
        ch.characteristics ->> 'interfloor_overlap_material'
            as overlap_material,
        ch.characteristics ->> 'roofing_material' as roofing_material,
        ch.characteristics as object_characteristics_json,

        address.full_address,
        address.postal_code,
        address.region_id as address_region_id,
        address.area as district,
        address.settlement,
        address.street,
        address.house,
        address.building,
        address.block,
        address.flat,
        address.office,
        address.fias_code,
        address.longitude,
        address.latitude,
        address.address_dgis_id,

        row_number() over (
            partition by contract.task_id, obj.id
            order by
                link.d_change desc nulls last,
                link.d_create desc nulls last,
                ch.version_start_date desc nulls last,
                ch.version_number desc nulls last,
                link.id desc,
                ch.id desc
        ) as object_number
    from contract_context contract
    join bps_request_ins_task_insurance_object link
        on link.parent_id = contract.task_id
    join base_insurance_object_characteristics ch
        on ch.id = link.characteristics_id
    join base_insurance_object obj
        on obj.id = ch.insurance_object_id
    left join base_geo_address address
        on address.id = obj.geo_address_id
    left join bps_contractor policyholder
        on policyholder.id = contract.policyholder_id
    left join bps_corporate_crm crm
        on crm.id = contract.corporate_crm_id
    where obj.elementary_obj_type = 'nedv_ul_and_ip'
      and obj.d_delete is null
),

selected_objects as (
    /*
    Шаг 5. Если объект несколько раз связан с одной задачей,
    оставляем одну самую позднюю запись связи.
    */
    select *
    from object_candidates
    where object_number = 1
),

selected_characteristics as (
    /* Шаг 6. Получаем список версий объектов для поиска их условий. */
    select distinct characteristics_id
    from selected_objects
),

condition_summary as (
    /*
    Шаг 7. У одной версии объекта может быть несколько вариантов условий.
    Сворачиваем их в одну строку, чтобы один объект не продублировался.
    */
    select
        cond.characteristics_id,
        count(*) as condition_count,
        min(cond.insured_sum) as condition_min_insured_sum,
        max(cond.insured_sum) as condition_max_insured_sum,
        count(distinct cond.insured_sum_currency) filter (
            where cond.insured_sum_currency is not null
        ) as condition_currency_count,
        string_agg(
            distinct cond.insured_sum_currency,
            ', '
            order by cond.insured_sum_currency
        ) filter (
            where cond.insured_sum_currency is not null
        ) as insured_sum_currency,
        min(cond.per_occurance_limit) as minimum_per_occurrence_limit,
        max(cond.per_occurance_limit) as maximum_per_occurrence_limit,
        jsonb_agg(
            jsonb_strip_nulls(
                jsonb_build_object(
                    'option_number', cond.terms_option_number,
                    'insured_sum', cond.insured_sum,
                    'currency', cond.insured_sum_currency,
                    'per_occurrence_limit', cond.per_occurance_limit
                )
            )
            order by cond.terms_option_number nulls last, cond.id
        ) as conditions_json
    from base_insurance_object_conditions cond
    join selected_characteristics selected
        on selected.characteristics_id = cond.characteristics_id
    group by cond.characteristics_id
),

object_data as (
    /* Шаг 8. Добавляем к каждому объекту найденные суммы и условия. */
    select
        obj.*,
        conditions.condition_count,
        conditions.condition_min_insured_sum,
        conditions.condition_max_insured_sum,
        conditions.condition_currency_count,
        conditions.insured_sum_currency,
        conditions.minimum_per_occurrence_limit,
        conditions.maximum_per_occurrence_limit,
        conditions.conditions_json
    from selected_objects obj
    left join condition_summary conditions
        on conditions.characteristics_id = obj.characteristics_id
),

objects_with_previous as (
    /*
    Шаг 9. Ищем тот же object_id в ближайшем предыдущем договоре
    и, если нашли, добавляем его предыдущую СС.
    */
    select
        current_object.*,
        case
            when previous_object.condition_min_insured_sum =
                 previous_object.condition_max_insured_sum
             and previous_object.condition_currency_count <= 1
            then previous_object.condition_max_insured_sum
        end as previous_object_insured_sum,
        previous_object.insured_sum_currency
            as previous_object_insured_sum_currency
    from object_data current_object
    left join object_data previous_object
        on previous_object.contract_id = current_object.previous_contract_id
       and previous_object.object_id = current_object.object_id
)

/* Шаг 10. Формируем итоговый набор колонок. */
select
    /* Основные ID. */
    obj.contract_id,
    obj.contract_number,
    obj.previous_contract_id,
    obj.root_contract_id,
    obj.request_id,
    obj.task_id,
    obj.task_object_link_id,
    obj.characteristics_id,
    obj.object_id,
    obj.geo_address_id,
    obj.policyholder_id,
    obj.corporate_crm_id,

    /* Договор и его даты. */
    obj.as_of_date,
    obj.contract_conclusion_date,
    obj.contract_sign_date,
    obj.contract_start_date,
    obj.contract_end_date,
    obj.contract_status,
    obj.ins_document_type,
    obj.contract_type,
    obj.contract_currency,
    obj.insurance_product,
    obj.insurance_program,

    /* Объект. */
    count(*) over (
        partition by obj.contract_id
    ) as real_estate_objects_in_contract,
    obj.object_group_id,
    obj.object_name,
    obj.object_description,
    obj.object_type,
    obj.elementary_obj_type,
    obj.total_area,
    obj.occupied_area,
    obj.construction_year,
    obj.capital_repair_year,
    obj.floors_count,
    obj.occupied_floor,
    obj.walls_material,
    obj.overlap_material,
    obj.roofing_material,
    obj.ownership_type,
    obj.is_leased,
    obj.insured_components,
    obj.activity_types,
    obj.risk_natures,
    obj.insurance_territory,

    /* Адрес. */
    obj.full_address,
    obj.original_address,
    obj.postal_code,
    obj.address_region_id,
    obj.district,
    obj.settlement,
    obj.street,
    obj.house,
    obj.building,
    obj.block,
    obj.flat,
    obj.office,
    obj.fias_code,
    obj.longitude,
    obj.latitude,
    obj.address_dgis_id,

    /* Страхователь, отрасль и сегмент. */
    obj.policyholder_inn,
    obj.policyholder_type,
    obj.policyholder_cdi_id,
    obj.policyholder_ogrn,
    obj.policyholder_kpp,
    obj.policyholder_name,
    obj.policyholder_company_form,
    obj.policyholder_registration_date,
    obj.crm_id,
    obj.crm_client_id,
    (obj.crm_client_id = obj.policyholder_id) as crm_client_is_policyholder,
    obj.crm_segment,
    obj.crm_macroindustry,
    obj.crm_industry,
    obj.crm_primary_occupation,
    obj.crm_specialization,
    obj.crm_okved,
    obj.business_segment,
    obj.task_industry,
    obj.task_subindustry,

    /*
    Все СС стоят рядом.
    СС договора относится ко всему договору и повторяется у его объектов.
    */
    obj.contract_insured_sum,
    obj.contract_amount_currency,
    min(obj.condition_min_insured_sum) over (
        partition by obj.contract_id
    ) as contract_real_estate_min_insured_sum,
    max(obj.condition_max_insured_sum) over (
        partition by obj.contract_id
    ) as contract_real_estate_max_insured_sum,
    obj.task_object_insured_sum,
    obj.task_object_insured_sum_currency,
    obj.condition_min_insured_sum,
    obj.condition_max_insured_sum,
    case
        /* Не выбираем случайную СС, если в условиях есть расхождения. */
        when obj.condition_min_insured_sum =
             obj.condition_max_insured_sum
         and obj.condition_currency_count <= 1
        then obj.condition_max_insured_sum
    end as insured_sum,
    obj.insured_sum_currency,
    obj.condition_currency_count,
    obj.previous_contract_insured_sum,
    obj.previous_contract_amount_currency,
    obj.previous_object_insured_sum,
    obj.previous_object_insured_sum_currency,

    /* Премии, стоимости и лимиты. */
    obj.contract_premium,
    obj.previous_contract_premium,
    obj.insurance_value,
    obj.insurance_value_currency,
    obj.insurance_value_basis,
    obj.is_pledged,
    obj.pledged_value,
    obj.task_object_per_occurrence_limit,
    obj.minimum_per_occurrence_limit,
    obj.maximum_per_occurrence_limit,

    /* Простая договорная история. */
    (obj.previous_contract_id is not null) as has_previous_contract,
    obj.previous_contract_number,
    obj.previous_contract_start_date,
    obj.previous_contract_end_date,

    /* Исходные данные для проверки. */
    obj.condition_count,
    obj.conditions_json,
    obj.characteristics_version_number,
    obj.characteristics_version_start_date,
    obj.characteristics_version_end_date,
    obj.characteristics_version_is_active,
    obj.object_characteristics_json,
    obj.task_type,
    obj.task_status,
    obj.ins_refuse
from objects_with_previous obj
order by
    obj.as_of_date desc nulls last,
    obj.contract_id,
    obj.object_id;
