/*
запускать в сфере

запрос собирает все неудаленные объекты недвижимости
если объект связан с подходящим договором данные договора заполняются
если связь не найдена объект остается в результате с пустыми полями договора

одна строка для связанного объекта означает объект в одном договоре
одна строка для несвязанного объекта означает его последнюю версию характеристик
*/

with task_candidates as (
    /* отбираем подходящие задачи оформления */
    select
        t.id as task_id,
        r.id as request_id,
        c.id as contract_id,
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
    /* оставляем последнюю подходящую задачу каждого договора */
    select
        task_id,
        request_id,
        contract_id
    from task_candidates
    where task_number = 1
),

linked_object_candidates as (
    /* находим недвижимость в выбранных задачах */
    select
        ch.insurance_object_id as object_id,
        ch.id as characteristics_id,
        link.id as task_object_link_id,
        selected.task_id,
        selected.request_id,
        selected.contract_id,
        row_number() over (
            partition by selected.task_id, ch.insurance_object_id
            order by
                link.d_change desc nulls last,
                link.d_create desc nulls last,
                ch.version_start_date desc nulls last,
                ch.version_number desc nulls last,
                link.id desc
        ) as link_number
    from selected_tasks selected
    join bps_request_ins_task_insurance_object link
        on link.parent_id = selected.task_id
    join base_insurance_object_characteristics ch
        on ch.id = link.characteristics_id
    join base_insurance_object obj
        on obj.id = ch.insurance_object_id
    where obj.elementary_obj_type = 'nedv_ul_and_ip'
      and obj.d_delete is null
),

selected_links as (
    /* убираем повторные связи одного объекта с одной задачей */
    select
        object_id,
        characteristics_id,
        task_object_link_id,
        task_id,
        request_id,
        contract_id
    from linked_object_candidates
    where link_number = 1
),

object_versions as (
    /* нумеруем версии характеристик каждого объекта */
    select
        obj.id as object_id,
        ch.id as characteristics_id,
        row_number() over (
            partition by obj.id
            order by
                ch.version_is_active desc nulls last,
                ch.version_number desc nulls last,
                ch.version_start_date desc nulls last,
                ch.id desc nulls last
        ) as version_number
    from base_insurance_object obj
    left join base_insurance_object_characteristics ch
        on ch.insurance_object_id = obj.id
    where obj.elementary_obj_type = 'nedv_ul_and_ip'
      and obj.d_delete is null
),

dataset_keys as (
    /* сохраняем все найденные связи с договорами */
    select
        linked.object_id,
        linked.characteristics_id,
        linked.task_object_link_id,
        linked.task_id,
        linked.request_id,
        linked.contract_id,
        'linked'::text as row_source
    from selected_links linked

    union all

    /* добавляем объекты для которых подходящий договор не найден */
    select
        version.object_id,
        version.characteristics_id,
        null::integer as task_object_link_id,
        null::integer as task_id,
        null::integer as request_id,
        null::integer as contract_id,
        'not_linked'::text as row_source
    from object_versions version
    where version.version_number = 1
      and not exists (
          select 1
          from selected_links linked
          where linked.object_id = version.object_id
      )
),

object_link_profile as (
    /* считаем со сколькими договорами связан объект */
    select
        object_id,
        count(distinct contract_id) as contract_count
    from selected_links
    group by object_id
),

selected_characteristics as (
    /* ограничиваем расчет условий версиями из итоговой выборки */
    select distinct characteristics_id
    from dataset_keys
    where characteristics_id is not null
),

condition_summary as (
    /* сворачиваем варианты условий в одну строку */
    select
        cond.characteristics_id,
        count(*) as condition_count,
        count(cond.insured_sum) as filled_insured_sum_count,
        count(distinct cond.insured_sum) filter (
            where cond.insured_sum is not null
        ) as distinct_insured_sum_count,
        min(cond.insured_sum) as minimum_insured_sum,
        max(cond.insured_sum) as maximum_insured_sum,
        count(distinct cond.insured_sum_currency) filter (
            where cond.insured_sum_currency is not null
        ) as currency_count,
        string_agg(
            distinct cond.insured_sum_currency,
            ', '
            order by cond.insured_sum_currency
        ) filter (
            where cond.insured_sum_currency is not null
        ) as insured_sum_currency,
        array_agg(
            distinct cond.terms_option_number
            order by cond.terms_option_number
        ) filter (
            where cond.terms_option_number is not null
        ) as terms_option_numbers,
        min(cond.per_occurance_limit) as minimum_per_occurrence_limit,
        max(cond.per_occurance_limit) as maximum_per_occurrence_limit,
        case
            when count(distinct cond.insured_sum) filter (
                where cond.insured_sum is not null
            ) = 1
             and count(distinct cond.insured_sum_currency) filter (
                where cond.insured_sum_currency is not null
            ) <= 1
            then max(cond.insured_sum)
        end as insured_sum
    from base_insurance_object_conditions cond
    join selected_characteristics selected
        on selected.characteristics_id = cond.characteristics_id
    group by cond.characteristics_id
)

select
    /* качество строки */
    keys.row_source,
    case
        when coalesce(profile.contract_count, 0) = 0 then 'not_linked'
        when profile.contract_count = 1 then 'linked'
        else 'multiple_contracts'
    end as contract_link_status,
    coalesce(profile.contract_count, 0) as contract_count,
    (keys.contract_id is not null) as has_contract,
    (address.id is not null) as has_address,
    (conditions.insured_sum is not null) as has_target,
    case
        when conditions.condition_count is null then 'no_conditions'
        when conditions.filled_insured_sum_count = 0 then 'target_is_empty'
        when conditions.distinct_insured_sum_count > 1 then 'several_target_values'
        when conditions.currency_count > 1 then 'several_currencies'
        when conditions.insured_sum <= 0 then 'target_is_not_positive'
        else 'target_is_usable'
    end as target_status,

    /* идентификаторы */
    keys.object_id,
    keys.characteristics_id,
    keys.task_object_link_id,
    keys.task_id,
    keys.request_id,
    keys.contract_id,
    obj.geo_address_id,
    contract.contractor_id,
    request.corporate_crm_id,

    /* целевая страховая сумма */
    conditions.insured_sum,
    conditions.insured_sum_currency,
    conditions.condition_count,
    conditions.filled_insured_sum_count,
    conditions.distinct_insured_sum_count,
    conditions.minimum_insured_sum,
    conditions.maximum_insured_sum,
    conditions.currency_count,
    conditions.terms_option_numbers,

    /* контрольные суммы */
    task_link.insured_sum as task_object_insured_sum,
    task_link.insured_sum_currency as task_object_insured_sum_currency,
    task.total_ins_contract_amount as contract_insured_sum,
    task.curr_ins_contract_amount as contract_insured_sum_currency,
    task.total_ins_contract_premium as contract_premium,
    ch.insurance_value,
    ch.insurance_value_currency,
    ch.insurance_value_basis,
    ch.pledged_value,
    conditions.minimum_per_occurrence_limit,
    conditions.maximum_per_occurrence_limit,

    /* объект */
    obj.obj_type as object_type,
    obj.elementary_obj_type,
    obj.obj_name as object_name,
    obj.description as object_description,
    obj.original_address,
    obj.active as object_is_active,
    obj.d_create as object_create_date,
    obj.d_change as object_change_date,

    /* характеристики объекта */
    ch.version_number as characteristics_version_number,
    ch.version_start_date as characteristics_version_start_date,
    ch.version_end_date as characteristics_version_end_date,
    ch.version_is_active as characteristics_version_is_active,
    ch.ownership_type,
    ch.is_pledged,
    ch.is_leased,
    ch.insured_components,
    ch.activity_types,
    ch.risk_natures,
    ch.insurance_territory,
    ch.has_losses,
    ch.insurance_object_loss_history,
    ch.characteristics ->> 'total_area_sq_m' as total_area,
    ch.characteristics ->> 'occupied_area_sq_m' as occupied_area,
    ch.characteristics ->> 'construction_year' as construction_year,
    ch.characteristics ->> 'last_capital_repair_year' as capital_repair_year,
    ch.characteristics ->> 'total_floors_count' as floors_count,
    ch.characteristics ->> 'occupied_floor' as occupied_floor,
    ch.characteristics ->> 'load_bearing_walls_material' as walls_material,
    ch.characteristics ->> 'interfloor_overlap_material' as overlap_material,
    ch.characteristics ->> 'roofing_material' as roofing_material,
    ch.characteristics ->> 'fire_alarm_system_availability'
        as fire_alarm_system_availability,
    ch.characteristics ->> 'fire_suppression_system_availability'
        as fire_suppression_system_availability,
    ch.characteristics ->> 'nearest_fire_station_distance_km'
        as nearest_fire_station_distance_km,
    ch.characteristics as object_characteristics_json,

    /* адрес */
    address.full_address,
    address.postal_code,
    address.region_id as address_region_id,
    address.area as address_area,
    address.settlement_type,
    address.settlement,
    address.street_type,
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

    /* договор */
    contract.n_contract as contract_number,
    contract.document_status as contract_status,
    contract.system_type as contract_source_system,
    contract.ins_product_sbs as contract_product,
    contract.d_sign_contract as contract_sign_date,
    contract.d_start_contract as contract_start_date,
    contract.d_end_contract as contract_end_date,
    contract.prevcontract_id as previous_contract_id,
    contract.rootcontract_id as root_contract_id,
    previous_contract.n_contract as previous_contract_number,
    previous_contract.d_start_contract as previous_contract_start_date,
    previous_contract.d_end_contract as previous_contract_end_date,

    /* задача и заявка */
    task.task_type,
    task.status as task_status,
    task.ins_document_type,
    task.ins_refuse,
    task.d_create as task_create_date,
    task.d_conclusion_ins_contract as contract_conclusion_date,
    task.ins_product as task_product,
    task.industry as task_industry,
    task.subindustry as task_subindustry,
    task.locations_count,
    task.multi_location,
    task.object_description as task_object_description,
    request.business_segment,
    request.sale_channel,
    request.ins_product as request_product,

    /* страхователь и crm */
    policyholder.inn as policyholder_inn,
    policyholder.company_name_short as policyholder_name,
    policyholder.cdi_id as policyholder_cdi_id,
    crm.segment as crm_segment,
    crm.macroindustry as crm_macroindustry,
    crm.industry as crm_industry,
    crm.okved as crm_okved,

    /* дата состояния строки */
    coalesce(
        task.d_conclusion_ins_contract::timestamp with time zone,
        contract.d_sign_contract,
        ch.version_start_date,
        obj.d_create
    ) as as_of_date
from dataset_keys keys
join base_insurance_object obj
    on obj.id = keys.object_id
left join base_insurance_object_characteristics ch
    on ch.id = keys.characteristics_id
left join condition_summary conditions
    on conditions.characteristics_id = keys.characteristics_id
left join bps_request_ins_task_insurance_object task_link
    on task_link.id = keys.task_object_link_id
left join bps_request_ins_task task
    on task.id = keys.task_id
left join bps_request_ins request
    on request.id = keys.request_id
left join bps_contract contract
    on contract.id = keys.contract_id
left join bps_contract previous_contract
    on previous_contract.id = contract.prevcontract_id
left join bps_contractor policyholder
    on policyholder.id = contract.contractor_id
left join bps_corporate_crm crm
    on crm.id = request.corporate_crm_id
left join base_geo_address address
    on address.id = obj.geo_address_id
left join object_link_profile profile
    on profile.object_id = keys.object_id
order by
    has_contract desc,
    as_of_date desc nulls last,
    keys.object_id;
