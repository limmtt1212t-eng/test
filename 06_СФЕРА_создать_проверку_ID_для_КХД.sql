/*
ЗАПУСКАТЬ В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Это один запрос. Он не ищет ЕГРН сразу.
Сначала он создаёт Oracle-запрос, который проверит разные способы
связать наши договоры "Сферы" с договорами КХД.

Для технической проверки берутся 30 договоров с наиболее заполненными
ключами. Это сделано, чтобы DBeaver не обрезал длинный текст. Когда рабочая
связь будет найдена, покрытие будет отдельно посчитано на всех договорах.

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
test_population as (
select *
from population
where contract_sbs_id is not null
or core_id is not null
or n_contract is not null
or n_contract_cleaned is not null
or task_policy_number is not null
or task_policy_number_1c is not null
or request_policy_number is not null
order by
(
case when contract_sbs_id is not null then 1 else 0 end
+ case when core_id is not null then 1 else 0 end
+ case when n_contract is not null then 1 else 0 end
+ case when n_contract_cleaned is not null then 1 else 0 end
+ case when task_policy_number is not null then 1 else 0 end
+ case when task_policy_number_1c is not null then 1 else 0 end
+ case when request_policy_number is not null then 1 else 0 end
) desc,
contract_id desc
limit 30
),
oracle_rows as (
select
contract_id,
'select '
|| chr(39) || contract_id::text || chr(39)
|| ' as sphere_contract_id, '
|| case
when nullif(btrim(contract_sbs_id), '') is null then 'null'
else chr(39)
|| replace(btrim(contract_sbs_id), chr(39), chr(39) || chr(39))
|| chr(39)
end
|| ' as contract_sbs_id, '
|| case
when nullif(btrim(core_id), '') is null then 'null'
else chr(39)
|| replace(btrim(core_id), chr(39), chr(39) || chr(39))
|| chr(39)
end
|| ' as core_id, '
|| case
when nullif(btrim(n_contract), '') is null then 'null'
else chr(39)
|| replace(btrim(n_contract), chr(39), chr(39) || chr(39))
|| chr(39)
end
|| ' as contract_number, '
|| case
when nullif(btrim(n_contract_cleaned), '') is null then 'null'
else chr(39)
|| replace(btrim(n_contract_cleaned), chr(39), chr(39) || chr(39))
|| chr(39)
end
|| ' as contract_number_cleaned, '
|| case
when nullif(btrim(task_policy_number), '') is null then 'null'
else chr(39)
|| replace(btrim(task_policy_number), chr(39), chr(39) || chr(39))
|| chr(39)
end
|| ' as task_policy_number, '
|| case
when nullif(btrim(task_policy_number_1c), '') is null then 'null'
else chr(39)
|| replace(btrim(task_policy_number_1c), chr(39), chr(39) || chr(39))
|| chr(39)
end
|| ' as task_policy_number_1c, '
|| case
when nullif(btrim(request_policy_number), '') is null then 'null'
else chr(39)
|| replace(btrim(request_policy_number), chr(39), chr(39) || chr(39))
|| chr(39)
end
|| ' as request_policy_number, '
|| case
when nullif(btrim(contract_contractor_sbs_id), '') is null then 'null'
else chr(39)
|| replace(btrim(contract_contractor_sbs_id), chr(39), chr(39) || chr(39))
|| chr(39)
end
|| ' as contract_contractor_sbs_id, '
|| case
when nullif(btrim(policyholder_sbs_id), '') is null then 'null'
else chr(39)
|| replace(btrim(policyholder_sbs_id), chr(39), chr(39) || chr(39))
|| chr(39)
end
|| ' as policyholder_sbs_id from dual'
as oracle_row
from test_population
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
)
select
(select count(distinct sphere_contract_id) from sphere_contracts)
as total_contracts,
(select count(distinct sphere_contract_id)
from sphere_contracts
where contract_sbs_id is not null) as h1_keys,
(select count(distinct s.sphere_contract_id)
from sphere_contracts s
join dm_risk_avatar.contracts k
on trim(k.contract_id) = trim(s.contract_sbs_id)) as h1_match,
(select count(distinct sphere_contract_id)
from sphere_contracts
where core_id is not null) as h2_keys,
(select count(distinct s.sphere_contract_id)
from sphere_contracts s
join dm_risk_avatar.contracts k
on trim(k.contract_id) = trim(s.core_id)) as h2_match,
(select count(distinct sphere_contract_id)
from raw_contract_numbers
where key_value is not null) as h3_keys,
(select count(distinct n.sphere_contract_id)
from raw_contract_numbers n
join dm_risk_avatar.contracts k
on upper(trim(k.contract_num)) = n.key_value
where n.key_value is not null) as h3_match,
(select count(distinct sphere_contract_id)
from raw_task_numbers
where key_value is not null) as h4_keys,
(select count(distinct n.sphere_contract_id)
from raw_task_numbers n
join dm_risk_avatar.contracts k
on upper(trim(k.contract_num)) = n.key_value
where n.key_value is not null) as h4_match,
(select count(distinct sphere_contract_id)
from normalized_number_keys) as h5_keys,
(select count(distinct n.sphere_contract_id)
from normalized_number_keys n
join dm_risk_avatar.contracts k
on regexp_replace(
upper(trim(k.contract_num)),
'[^[:alnum:]]',
''
) = n.key_value) as h5_match,
(select count(distinct sphere_contract_id)
from client_keys) as h6_keys,
(select count(distinct c.sphere_contract_id)
from client_keys c
join dm_risk_avatar.contracts k
on trim(k.client_id) = c.key_value) as h6_match
from dual
$oracle$
as "Готовый Oracle запрос"
from oracle_rows;
