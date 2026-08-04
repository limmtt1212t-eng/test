/*
ЗАПУСКАТЬ В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Это один запрос. Он не ищет ЕГРН сразу.
Сначала он создаёт Oracle-запрос, который проверит разные способы
связать наши договоры "Сферы" с договорами КХД.

Порядок:
1. Выполнить весь этот файл в "Сфере".
2. Скопировать содержимое единственной ячейки "Готовый Oracle запрос".
3. Вставить в пустой редактор подключения КХД 1.0.
4. Выполнить в Oracle.
5. Результат можно передать без договорных номеров: там только количества.
*/

with task_candidates as (
select
c.id as contract_id,
c.sbs_id as contract_sbs_id,
c.core_id,
c.n_contract,
c.n_contract_cleaned,
c.id_contractor as contract_contractor_sbs_id,
policyholder.sbs_id as policyholder_sbs_id,
r.last_request_ins_task_policy_num as request_policy_number,
t.contract_num_policy as task_policy_number,
t.contract_num_policy_1c as task_policy_number_1c,
t.id as task_id,
row_number() over (
partition by c.id
order by
t.d_conclusion_ins_contract desc nulls last,
t.d_create desc nulls last,
t.d_change desc nulls last,
t.id desc
) as task_rank
from bps_request_ins_task t
join bps_request_ins r
on r.id = t.request_ins_id
join bps_contract c
on c.id = r.contract_id
left join bps_contractor policyholder
on policyholder.id = c.contractor_id
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
select *
from task_candidates
where task_rank = 1
),
population as (
select task.*
from selected_tasks task
where exists (
select 1
from bps_request_ins_task_insurance_object tobj
join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
join base_insurance_object obj
on obj.id = ch.insurance_object_id
where tobj.parent_id = task.task_id
and obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
)
),
oracle_rows as (
select
contract_id,
'select '
|| quote_nullable(contract_id::text)
|| ' as sphere_contract_id, '
|| quote_nullable(nullif(btrim(contract_sbs_id), ''))
|| ' as contract_sbs_id, '
|| quote_nullable(nullif(btrim(core_id), ''))
|| ' as core_id, '
|| quote_nullable(nullif(btrim(n_contract), ''))
|| ' as contract_number, '
|| quote_nullable(nullif(btrim(n_contract_cleaned), ''))
|| ' as contract_number_cleaned, '
|| quote_nullable(nullif(btrim(task_policy_number), ''))
|| ' as task_policy_number, '
|| quote_nullable(nullif(btrim(task_policy_number_1c), ''))
|| ' as task_policy_number_1c, '
|| quote_nullable(nullif(btrim(request_policy_number), ''))
|| ' as request_policy_number, '
|| quote_nullable(nullif(btrim(contract_contractor_sbs_id), ''))
|| ' as contract_contractor_sbs_id, '
|| quote_nullable(nullif(btrim(policyholder_sbs_id), ''))
|| ' as policyholder_sbs_id from dual'
as oracle_row
from population
)
select
$oracle$
with sphere_contracts as (
$oracle$
|| string_agg(
oracle_row,
E'\nunion all\n'
order by contract_id
)
|| $oracle$
),
raw_contract_numbers as (
select sphere_contract_id, upper(trim(contract_number)) as key_value
from sphere_contracts
union
select sphere_contract_id, upper(trim(contract_number_cleaned))
from sphere_contracts
),
raw_task_numbers as (
select sphere_contract_id, upper(trim(task_policy_number)) as key_value
from sphere_contracts
union
select sphere_contract_id, upper(trim(task_policy_number_1c))
from sphere_contracts
union
select sphere_contract_id, upper(trim(request_policy_number))
from sphere_contracts
),
all_number_keys as (
select sphere_contract_id, key_value
from raw_contract_numbers
where key_value is not null
union
select sphere_contract_id, key_value
from raw_task_numbers
where key_value is not null
),
normalized_number_keys as (
select distinct
sphere_contract_id,
regexp_replace(key_value, '[^[:alnum:]]', '') as key_value
from all_number_keys
where regexp_replace(key_value, '[^[:alnum:]]', '') is not null
),
client_keys as (
select sphere_contract_id, trim(contract_contractor_sbs_id) as key_value
from sphere_contracts
where contract_contractor_sbs_id is not null
union
select sphere_contract_id, trim(policyholder_sbs_id)
from sphere_contracts
where policyholder_sbs_id is not null
),
hypotheses as (
select
1 as hypothesis_number,
'bps_contract.sbs_id = CONTRACTS.CONTRACT_ID' as hypothesis,
(select count(distinct sphere_contract_id)
from sphere_contracts
where contract_sbs_id is not null) as available_sphere_contracts,
count(distinct s.sphere_contract_id) as matched_sphere_contracts,
count(distinct k.contract_id) as matched_khd_values
from sphere_contracts s
join dm_risk_avatar.contracts k
on trim(k.contract_id) = trim(s.contract_sbs_id)

union all

select
2,
'bps_contract.core_id = CONTRACTS.CONTRACT_ID',
(select count(distinct sphere_contract_id)
from sphere_contracts
where core_id is not null),
count(distinct s.sphere_contract_id),
count(distinct k.contract_id)
from sphere_contracts s
join dm_risk_avatar.contracts k
on trim(k.contract_id) = trim(s.core_id)

union all

select
3,
'bps_contract number = CONTRACTS.CONTRACT_NUM exact',
(select count(distinct sphere_contract_id)
from raw_contract_numbers
where key_value is not null),
count(distinct n.sphere_contract_id),
count(distinct k.contract_id)
from raw_contract_numbers n
join dm_risk_avatar.contracts k
on upper(trim(k.contract_num)) = n.key_value
where n.key_value is not null

union all

select
4,
'task or request policy number = CONTRACTS.CONTRACT_NUM exact',
(select count(distinct sphere_contract_id)
from raw_task_numbers
where key_value is not null),
count(distinct n.sphere_contract_id),
count(distinct k.contract_id)
from raw_task_numbers n
join dm_risk_avatar.contracts k
on upper(trim(k.contract_num)) = n.key_value
where n.key_value is not null

union all

select
5,
'all policy numbers = CONTRACTS.CONTRACT_NUM normalized',
(select count(distinct sphere_contract_id)
from normalized_number_keys),
count(distinct n.sphere_contract_id),
count(distinct k.contract_id)
from normalized_number_keys n
join dm_risk_avatar.contracts k
on regexp_replace(
upper(trim(k.contract_num)),
'[^[:alnum:]]',
''
) = n.key_value

union all

select
6,
'contractor SBS ID = CONTRACTS.CLIENT_ID client level only',
(select count(distinct sphere_contract_id)
from client_keys),
count(distinct c.sphere_contract_id),
count(distinct k.client_id)
from client_keys c
join dm_risk_avatar.contracts k
on trim(k.client_id) = c.key_value

union all

select
7,
'bps_contract.sbs_id = STG_CLIENT_CONTRACT.CONTRACT_ID',
(select count(distinct sphere_contract_id)
from sphere_contracts
where contract_sbs_id is not null),
count(distinct s.sphere_contract_id),
count(distinct k.contract_id)
from sphere_contracts s
join dm_risk_avatar.stg_client_contract k
on trim(k.contract_id) = trim(s.contract_sbs_id)

union all

select
8,
'bps_contract.core_id = STG_CLIENT_CONTRACT.DOCUMENT_ID',
(select count(distinct sphere_contract_id)
from sphere_contracts
where core_id is not null),
count(distinct s.sphere_contract_id),
count(distinct k.document_id)
from sphere_contracts s
join dm_risk_avatar.stg_client_contract k
on trim(k.document_id) = trim(s.core_id)

union all

select
9,
'bps_contract.sbs_id = STG_ADDRESS_ZUD.CONTRACT_ID',
(select count(distinct sphere_contract_id)
from sphere_contracts
where contract_sbs_id is not null),
count(distinct s.sphere_contract_id),
count(distinct k.contract_id)
from sphere_contracts s
join dm_risk_avatar.stg_address_zud k
on trim(k.contract_id) = trim(s.contract_sbs_id)

union all

select
10,
'bps_contract.sbs_id = STG_CONTRACT_OBJRISK.CONTRACT_ID',
(select count(distinct sphere_contract_id)
from sphere_contracts
where contract_sbs_id is not null),
count(distinct s.sphere_contract_id),
count(distinct k.contract_id)
from sphere_contracts s
join dm_risk_avatar.stg_contract_objrisk k
on trim(k.contract_id) = trim(s.contract_sbs_id)

union all

select
11,
'all policy numbers = STG_CONTRACT_OBJRISK.CONTRACT_NUM normalized',
(select count(distinct sphere_contract_id)
from normalized_number_keys),
count(distinct n.sphere_contract_id),
count(distinct k.contract_id)
from normalized_number_keys n
join dm_risk_avatar.stg_contract_objrisk k
on regexp_replace(
upper(trim(k.contract_num)),
'[^[:alnum:]]',
''
) = n.key_value
)
select
hypothesis_number as "Номер гипотезы",
hypothesis as "Что проверили",
(select count(distinct sphere_contract_id) from sphere_contracts)
as "Всего договоров Сферы",
available_sphere_contracts as "Договоров с заполненным ключом",
matched_sphere_contracts as "Договоров Сферы найдено",
matched_khd_values as "Значений найдено в КХД",
round(
100 * matched_sphere_contracts /
nullif((select count(distinct sphere_contract_id) from sphere_contracts), 0),
1
) as "Найдено от всех процентов",
round(
100 * matched_sphere_contracts /
nullif(available_sphere_contracts, 0),
1
) as "Найдено среди заполненных процентов"
from hypotheses
order by hypothesis_number
$oracle$
as "Готовый Oracle запрос"
from oracle_rows;
