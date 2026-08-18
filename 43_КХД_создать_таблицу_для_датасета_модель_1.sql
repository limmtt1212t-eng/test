/*
Запускать в Oracle перед загрузкой CSV из запроса 41.

Таблица является загрузочным слоем. Значения принимаются как текст,
чтобы при импорте не потерять формат дат, сумм, логических полей и массивов.
Два больших JSON сохраняются как CLOB.

Запускать CREATE TABLE только один раз.
Если Oracle вернул ORA-00955, таблица уже существует.
*/

create table SPHERE_M1_STAGE (
    contract_id varchar2(200),
    contract_number varchar2(500),
    previous_contract_id varchar2(200),
    root_contract_id varchar2(200),
    request_id varchar2(200),
    task_id varchar2(200),
    task_object_link_id varchar2(200),
    characteristics_id varchar2(200),
    object_id varchar2(200),
    geo_address_id varchar2(200),
    policyholder_id varchar2(200),
    corporate_crm_id varchar2(200),

    as_of_date varchar2(200),
    contract_conclusion_date varchar2(200),
    contract_sign_date varchar2(200),
    contract_start_date varchar2(200),
    contract_end_date varchar2(200),
    contract_status varchar2(500),
    ins_document_type varchar2(500),
    contract_type varchar2(500),
    contract_currency varchar2(100),
    insurance_product varchar2(1000),
    insurance_program varchar2(1000),

    real_estate_objects_in_contract varchar2(200),
    object_group_id varchar2(200),
    object_name varchar2(4000),
    object_description clob,
    object_type varchar2(500),
    elementary_obj_type varchar2(500),
    total_area varchar2(500),
    occupied_area varchar2(500),
    construction_year varchar2(500),
    capital_repair_year varchar2(500),
    floors_count varchar2(500),
    occupied_floor varchar2(500),
    walls_material varchar2(4000),
    overlap_material varchar2(4000),
    roofing_material varchar2(4000),
    ownership_type varchar2(1000),
    is_leased varchar2(50),
    insured_components clob,
    activity_types clob,
    risk_natures clob,
    insurance_territory clob,

    full_address varchar2(4000),
    original_address clob,
    postal_code varchar2(100),
    address_region_id varchar2(200),
    district varchar2(1000),
    settlement varchar2(1000),
    street varchar2(1000),
    house varchar2(500),
    building varchar2(500),
    block varchar2(500),
    flat varchar2(500),
    office varchar2(500),
    fias_code varchar2(500),
    longitude varchar2(200),
    latitude varchar2(200),
    address_dgis_id varchar2(500),

    policyholder_inn varchar2(100),
    policyholder_type varchar2(500),
    policyholder_cdi_id varchar2(500),
    policyholder_ogrn varchar2(100),
    policyholder_kpp varchar2(100),
    policyholder_name varchar2(4000),
    policyholder_company_form varchar2(1000),
    policyholder_registration_date varchar2(200),
    crm_id varchar2(200),
    crm_client_id varchar2(200),
    crm_client_is_policyholder varchar2(50),
    crm_segment varchar2(1000),
    crm_macroindustry varchar2(1000),
    crm_industry varchar2(1000),
    crm_primary_occupation varchar2(4000),
    crm_specialization varchar2(4000),
    crm_okved varchar2(4000),
    business_segment varchar2(1000),
    task_industry varchar2(1000),
    task_subindustry varchar2(1000),

    contract_insured_sum varchar2(500),
    contract_amount_currency varchar2(100),
    contract_real_estate_min_insured_sum varchar2(500),
    contract_real_estate_max_insured_sum varchar2(500),
    task_object_insured_sum varchar2(500),
    task_object_insured_sum_currency varchar2(100),
    condition_min_insured_sum varchar2(500),
    condition_max_insured_sum varchar2(500),
    insured_sum varchar2(500),
    insured_sum_currency varchar2(500),
    condition_currency_count varchar2(200),
    previous_contract_insured_sum varchar2(500),
    previous_contract_amount_currency varchar2(100),
    previous_object_insured_sum varchar2(500),
    previous_object_insured_sum_currency varchar2(100),

    contract_premium varchar2(500),
    previous_contract_premium varchar2(500),
    insurance_value varchar2(500),
    insurance_value_currency varchar2(100),
    insurance_value_basis varchar2(4000),
    is_pledged varchar2(50),
    pledged_value varchar2(500),
    task_object_per_occurrence_limit varchar2(500),
    minimum_per_occurrence_limit varchar2(500),
    maximum_per_occurrence_limit varchar2(500),

    has_previous_contract varchar2(50),
    previous_contract_number varchar2(500),
    previous_contract_start_date varchar2(200),
    previous_contract_end_date varchar2(200),

    condition_count varchar2(200),
    conditions_json clob,
    characteristics_version_number varchar2(200),
    characteristics_version_start_date varchar2(200),
    characteristics_version_end_date varchar2(200),
    characteristics_version_is_active varchar2(50),
    object_characteristics_json clob,
    task_type varchar2(500),
    task_status varchar2(500),
    ins_refuse varchar2(50)
);


/* Проверка после импорта. */
select
    count(*) as loaded_rows,
    count(object_id) as rows_with_object_id,
    count(distinct contract_id) as distinct_contracts,
    count(insured_sum) as rows_with_target,
    count(full_address) as rows_with_address
from SPHERE_M1_STAGE;


/* Эти значения помогают убедиться, что логические поля загрузились текстом. */
select distinct
    crm_client_is_policyholder,
    is_leased,
    is_pledged,
    has_previous_contract,
    characteristics_version_is_active,
    ins_refuse
from SPHERE_M1_STAGE;
