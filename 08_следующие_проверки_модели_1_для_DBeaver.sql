/*
МОДЕЛЬ 1. СЛЕДУЮЩИЕ ПРОВЕРКИ ПОСЛЕ ВОРОНКИ 15 627 -> 789 -> 485 -> 484
===========================================================================

В этом файле пять самостоятельных запросов.

Запускать строго по одному:
1. Выделить мышкой один запрос целиком, начиная с WITH.
2. Включить в выделение завершающую точку с запятой.
3. Нажать Ctrl+Enter.
4. Сохранить агрегированный результат и дату запуска.

Запросы только читают данные. Они не выводят номера договоров, ИНН,
названия клиентов и адреса объектов.

Текущее правило отбора является техническим исследовательским правилом.
Оно пока не доказывает, что договор юридически заключен.

Порядок запуска:
1. Продукты и годы.
2. Типы объектов и состояние связей.
3. Зерно и размножение строк.
4. Заполненность признаков объекта.
5. Кандидаты на целевую стоимость.
*/


/* ========================================================================
ЗАПРОС 1 ИЗ 5. ПРОДУКТЫ И ГОДЫ

Главный вопрос:
малое число договоров с объектами объясняется составом страховых продуктов
или отсутствием объектных связей внутри имущественных продуктов?

Продукт выводится отдельно из задачи, заявки и договора. Эти поля намеренно
не объединяются через COALESCE: сначала нужно увидеть, совпадают ли они.
Поля задачи и заявки берутся из одной выбранной задачи договора.

Год определяется только по дате начала договора c.d_start_contract.
Если она не заполнена, договор попадет в строку с пустым годом.

В первой строке результата "0. ИТОГО" должна воспроизвестись вся текущая
воронка. Остальные строки показывают выбранную задачу по одному разрезу за
раз. Строки разных разрезов между собой складывать нельзя.

Числа могут немного измениться, если база обновилась после прошлого запуска.
======================================================================== */

with task_candidates as (
select
c.id as contract_id,
c.d_start_contract as contract_start_date,
c.system_type as contract_source_system,
c.ins_product_sbs as contract_product,
c.ins_program as contract_program,
r.ins_product as request_product,
r.business_line as request_business_line,
t.id as task_id,
t.ins_product as task_product,
t.d_conclusion_ins_contract,
t.d_create as task_create_date,
t.d_change as task_change_date,
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
task_object_profile as (
select
task.task_id,
count(distinct tobj.id) as object_link_count,
count(distinct ch.id) as characteristics_count,
count(distinct obj.id) filter (
where obj.id is not null
) as resolved_object_count,
count(distinct obj.id) filter (
where obj.id is not null
and obj.d_delete is null
) as live_object_count,
count(distinct obj.id) filter (
where obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
) as real_estate_object_count
from task_candidates task
left join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = task.task_id
left join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
left join base_insurance_object obj
on obj.id = ch.insurance_object_id
group by task.task_id
),
task_profile as (
select
task.*,
profile.object_link_count > 0 as has_object_link,
profile.characteristics_count > 0 as has_characteristics,
profile.resolved_object_count > 0 as has_resolved_object,
profile.live_object_count > 0 as has_live_object,
profile.real_estate_object_count > 0 as has_real_estate
from task_candidates task
join task_object_profile profile
on profile.task_id = task.task_id
),
contract_any_task_profile as (
select
contract_id,
bool_or(has_object_link) as has_link_in_any_task,
bool_or(has_characteristics) as has_characteristics_in_any_task,
bool_or(has_resolved_object) as has_object_in_any_task,
bool_or(has_live_object) as has_live_object_in_any_task,
bool_or(has_real_estate) as has_real_estate_in_any_task
from task_profile
group by contract_id
),
selected_task_profile as (
select *
from task_profile
where task_rank = 1
),
contract_profile as (
select
selected.contract_id,
extract(year from selected.contract_start_date)::integer as contract_start_year,
selected.contract_source_system,
selected.request_business_line,
selected.task_product,
selected.request_product,
selected.contract_product,
selected.contract_program,
any_task.has_link_in_any_task,
any_task.has_characteristics_in_any_task,
any_task.has_object_in_any_task,
any_task.has_live_object_in_any_task,
any_task.has_real_estate_in_any_task,
selected.has_object_link as has_link_in_selected_task,
selected.has_resolved_object as has_object_in_selected_task,
selected.has_live_object as has_live_object_in_selected_task,
selected.has_real_estate as has_real_estate_in_selected_task
from selected_task_profile selected
join contract_any_task_profile any_task
on any_task.contract_id = selected.contract_id
),
classification_rows as (
select
profile.contract_id,
profile.contract_start_year,
profile.has_link_in_any_task,
profile.has_real_estate_in_any_task,
profile.has_link_in_selected_task,
profile.has_object_in_selected_task,
profile.has_live_object_in_selected_task,
profile.has_real_estate_in_selected_task,
classification.classification_source,
classification.classification_value,
false as is_total_row
from contract_profile profile
cross join lateral (
values
(
'1. Только год',
'[ВСЕ ПРОДУКТЫ]'
),
(
'2. Продукт из выбранной задачи',
coalesce(nullif(btrim(profile.task_product), ''), '[НЕ ЗАПОЛНЕНО]')
),
(
'3. Продукт из заявки выбранной задачи',
coalesce(nullif(btrim(profile.request_product), ''), '[НЕ ЗАПОЛНЕНО]')
),
(
'4. Продукт из договора',
coalesce(nullif(btrim(profile.contract_product), ''), '[НЕ ЗАПОЛНЕНО]')
),
(
'5. Линия бизнеса из заявки выбранной задачи',
coalesce(
nullif(btrim(profile.request_business_line), ''),
'[НЕ ЗАПОЛНЕНО]'
)
),
(
'6. Программа из договора',
coalesce(nullif(btrim(profile.contract_program), ''), '[НЕ ЗАПОЛНЕНО]')
),
(
'7. Система-источник договора',
coalesce(
nullif(btrim(profile.contract_source_system), ''),
'[НЕ ЗАПОЛНЕНО]'
)
)
) as classification(
classification_source,
classification_value
)
),
analysis_rows as (
select *
from classification_rows

union all

select
profile.contract_id,
null::integer as contract_start_year,
profile.has_link_in_any_task,
profile.has_real_estate_in_any_task,
profile.has_link_in_selected_task,
profile.has_object_in_selected_task,
profile.has_live_object_in_selected_task,
profile.has_real_estate_in_selected_task,
'0. ИТОГО' as classification_source,
'[ВСЕ ДОГОВОРЫ]' as classification_value,
true as is_total_row
from contract_profile profile
)
select
contract_start_year
as "Год_начала_договора",
classification_source
as "Разрез",
classification_value
as "Значение",
count(*)
as "Договоров_с_подходящей_задачей",
case
when is_total_row
then count(*) filter (
where has_link_in_any_task
)
else null
end
as "Со_связью_на_объект_в_любой_задаче",
count(*) filter (
where has_link_in_selected_task
)
as "Со_связью_на_объект_в_выбранной_задаче",
count(*) filter (
where has_object_in_selected_task
)
as "С_найденным_объектом_в_выбранной_задаче",
count(*) filter (
where has_live_object_in_selected_task
)
as "С_неудаленным_объектом_в_выбранной_задаче",
case
when is_total_row
then count(*) filter (
where has_real_estate_in_any_task
)
else null
end
as "С_недвижимостью_в_любой_задаче",
count(*) filter (
where has_real_estate_in_selected_task
)
as "С_недвижимостью_в_выбранной_задаче",
round(
100.0 * count(*) filter (
where has_link_in_selected_task
) / nullif(count(*), 0),
1
)
as "Покрытие_связью_процентов",
round(
100.0 * count(*) filter (
where has_real_estate_in_selected_task
) / nullif(count(*), 0),
1
)
as "Доля_недвижимости_процентов"
from analysis_rows
group by
contract_start_year,
classification_source,
classification_value,
is_total_row
order by
classification_source,
contract_start_year desc nulls last,
"Договоров_с_подходящей_задачей" desc,
classification_value;


/* ========================================================================
ЗАПРОС 2 ИЗ 5. ТИПЫ ОБЪЕКТОВ И СОСТОЯНИЕ СВЯЗЕЙ

Показывает, какие типы объектов находятся в выбранных задачах и где именно
обрывается цепочка задача -> строка связи -> характеристики -> объект.

Текущее техническое правило исключает логически удаленные объекты, но не
фильтрует поле obj.active. Поэтому неактивные объекты показаны отдельно.

Важно: один договор может содержать несколько типов и состояний объектов.
Поэтому столбец "Договоров" нельзя складывать по строкам результата.
======================================================================== */

with task_candidates as (
select
c.id as contract_id,
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
contract_id,
task_id
from task_candidates
where task_rank = 1
),
object_rows as (
select
task.contract_id,
task.task_id,
tobj.id as task_object_link_id,
ch.id as characteristics_id,
obj.id as object_id,
obj.obj_type,
obj.elementary_obj_type,
case
when tobj.id is null
then '1. Нет строки связи задача-объект'
when ch.id is null
then '2. Не найдены характеристики'
when obj.id is null
then '3. Не найден объект'
when obj.d_delete is not null
then '4. Объект логически удален'
when obj.active is false
then '5. Объект неактивен'
when obj.active is null
then '6. Поле активности объекта не заполнено'
else '7. Связь полностью найдена'
end as link_status
from selected_tasks task
left join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = task.task_id
left join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
left join base_insurance_object obj
on obj.id = ch.insurance_object_id
)
select
link_status
as "Состояние_связи",
coalesce(
nullif(btrim(elementary_obj_type), ''),
'[ПОДТИП НЕ ЗАПОЛНЕН]'
)
as "elementary_obj_type",
coalesce(
nullif(btrim(obj_type), ''),
'[ТИП НЕ ЗАПОЛНЕН]'
)
as "obj_type",
count(distinct contract_id)
as "Договоров",
count(distinct task_id)
as "Задач",
count(distinct task_object_link_id)
as "Строк_связи_задача_объект",
count(distinct characteristics_id)
as "Наборов_характеристик",
count(distinct object_id)
as "Уникальных_object_id"
from object_rows
group by
link_status,
elementary_obj_type,
obj_type
order by
link_status,
"Договоров" desc,
"Уникальных_object_id" desc;


/* ========================================================================
ЗАПРОС 3 ИЗ 5. ЗЕРНО И РАЗМНОЖЕНИЕ СТРОК

Проверяет только недвижимость nedv_ul_and_ip в выбранной задаче.

Главные вопросы:
- сколько технических объектных строк получилось;
- есть ли несколько связей на одну пару задача + объект;
- встречается ли один object_id в нескольких договорах;
- размножают ли строки варианты условий страхования.

Результат: одна строка с агрегированными числами.
======================================================================== */

with task_candidates as (
select
c.id as contract_id,
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
contract_id,
task_id
from task_candidates
where task_rank = 1
),
eligible_tasks as (
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
raw_property_links as (
select
task.contract_id,
task.task_id,
tobj.id as task_object_link_id,
tobj.characteristics_id,
obj.id as object_id
from eligible_tasks task
join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = task.task_id
join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
join base_insurance_object obj
on obj.id = ch.insurance_object_id
where obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
),
task_object_profile as (
select
task_id,
object_id,
count(*) as link_count,
count(distinct characteristics_id) as characteristics_count
from raw_property_links
group by
task_id,
object_id
),
object_usage as (
select
object_id,
count(distinct contract_id) as contract_count
from raw_property_links
group by object_id
),
contract_profile as (
select
contract_id,
count(distinct object_id) as object_count
from raw_property_links
group by contract_id
),
condition_profile as (
select
object_link.task_object_link_id,
count(cond.id) as condition_count
from raw_property_links object_link
left join base_insurance_object_conditions cond
on cond.characteristics_id = object_link.characteristics_id
group by object_link.task_object_link_id
)
select
(select count(*) from eligible_tasks)
as "Договоров_и_выбранных_задач_в_популяции",
(select count(*) from raw_property_links)
as "Сырых_строк_связи_с_недвижимостью",
(select count(*) from task_object_profile)
as "Уникальных_пар_задача_объект",
(select count(distinct object_id) from raw_property_links)
as "Уникальных_object_id",
(select count(*) from task_object_profile where link_count > 1)
as "Пар_задача_объект_с_повторными_связями",
(select count(*) from task_object_profile where characteristics_count > 1)
as "Пар_задача_объект_с_несколькими_характеристиками",
coalesce(
(select max(link_count) from task_object_profile),
0
)
as "Максимум_связей_на_пару_задача_объект",
(select count(*) from object_usage where contract_count > 1)
as "object_id_в_нескольких_договорах",
coalesce(
(select max(contract_count) from object_usage),
0
)
as "Максимум_договоров_на_один_object_id",
(select count(*) from contract_profile where object_count > 1)
as "Договоров_с_несколькими_объектами",
round(
coalesce(
(select avg(object_count) from contract_profile),
0
),
2
)
as "Среднее_объектов_на_договор",
coalesce(
(select max(object_count) from contract_profile),
0
)
as "Максимум_объектов_в_договоре",
(select count(*) from condition_profile where condition_count = 0)
as "Строк_связи_без_условий_страхования",
(select count(*) from condition_profile where condition_count > 1)
as "Строк_связи_с_несколькими_условиями",
coalesce(
(select max(condition_count) from condition_profile),
0
)
as "Максимум_условий_на_строку_связи",
coalesce(
(select sum(condition_count) from condition_profile),
0
)
as "Строк_после_INNER_JOIN_с_условиями";


/* ========================================================================
ЗАПРОС 4 ИЗ 5. ЗАПОЛНЕННОСТЬ ПРИЗНАКОВ ОБЪЕКТА

Сначала технически выбирается одна строка на пару задача + object_id.
Знаменатель всех показателей в результате — получившиеся объектные строки,
а не договоры.

Площадь, год постройки и материал стен берутся из JSON как текст. Запрос
не пытается преобразовать их в числа и поэтому не упадет на грязном значении.

Кроме отдельно указанной длины ИНН, здесь проверяется заполненность, а не
качество значений. Непустой адрес, ФИАС, координаты, площадь или год еще
не означают, что значение корректно и пригодно для модели.
======================================================================== */

with task_candidates as (
select
c.id as contract_id,
c.contractor_id,
r.corporate_crm_id,
t.id as task_id,
t.industry as task_industry,
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
contract_id,
contractor_id,
corporate_crm_id,
task_id,
task_industry
from task_candidates
where task_rank = 1
),
eligible_tasks as (
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
object_candidates as (
select
task.contract_id,
task.task_id,
obj.id as object_id,
obj.description as object_description,
obj.original_address,
geo.full_address,
geo.fias_code,
geo.latitude,
geo.longitude,
geo.address_dgis_id,
ch.characteristics,
policyholder.inn as policyholder_inn,
regexp_replace(
coalesce(policyholder.inn, ''),
'[^0-9]',
'',
'g'
) as policyholder_inn_digits,
policyholder.d_delete as policyholder_delete_date,
crm.industry as crm_industry,
crm.d_delete as crm_delete_date,
task.task_industry,
row_number() over (
partition by task.task_id, obj.id
order by
tobj.d_change desc nulls last,
tobj.d_create desc nulls last,
ch.version_start_date desc nulls last,
ch.version_number desc nulls last,
tobj.id desc,
ch.id desc
) as object_rank
from eligible_tasks task
join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = task.task_id
join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
join base_insurance_object obj
on obj.id = ch.insurance_object_id
left join base_geo_address geo
on geo.id = obj.geo_address_id
left join bps_contractor policyholder
on policyholder.id = task.contractor_id
left join bps_corporate_crm crm
on crm.id = task.corporate_crm_id
where obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
),
object_rows as (
select *
from object_candidates
where object_rank = 1
),
summary as (
select
count(*) as total_objects,
count(*) filter (
where nullif(policyholder_inn_digits, '') is not null
) as with_inn_digits,
count(*) filter (
where length(policyholder_inn_digits) in (10, 12)
) as with_inn_valid_length,
count(*) filter (
where length(policyholder_inn_digits) in (10, 12)
and policyholder_delete_date is null
) as with_inn_valid_length_live_record,
count(*) filter (
where nullif(btrim(full_address), '') is not null
) as with_normalized_address,
count(*) filter (
where nullif(btrim(original_address), '') is not null
) as with_original_address,
count(*) filter (
where coalesce(
nullif(btrim(full_address), ''),
nullif(btrim(original_address), '')
) is not null
) as with_any_address,
count(*) filter (
where nullif(btrim(fias_code), '') is not null
) as with_fias,
count(*) filter (
where latitude is not null
and longitude is not null
) as with_coordinates,
count(*) filter (
where nullif(btrim(address_dgis_id), '') is not null
) as with_dgis_id,
count(*) filter (
where nullif(btrim(object_description), '') is not null
) as with_description,
count(*) filter (
where jsonb_typeof(characteristics) = 'object'
and characteristics <> '{}'::jsonb
) as with_nonempty_json_object,
count(*) filter (
where nullif(btrim(characteristics ->> 'total_area_sq_m'), '') is not null
) as with_area,
count(*) filter (
where nullif(btrim(characteristics ->> 'construction_year'), '') is not null
) as with_construction_year,
count(*) filter (
where nullif(
btrim(characteristics ->> 'load_bearing_walls_material'),
''
) is not null
) as with_wall_material,
count(*) filter (
where nullif(btrim(crm_industry), '') is not null
) as with_crm_industry,
count(*) filter (
where nullif(btrim(crm_industry), '') is not null
and crm_delete_date is null
) as with_crm_industry_live_record,
count(*) filter (
where nullif(btrim(task_industry), '') is not null
) as with_task_industry,
count(*) filter (
where coalesce(
nullif(btrim(crm_industry), ''),
nullif(btrim(task_industry), '')
) is not null
) as with_any_industry,
count(*) filter (
where nullif(btrim(crm_industry), '') is not null
and nullif(btrim(task_industry), '') is not null
and lower(btrim(crm_industry)) <> lower(btrim(task_industry))
) as with_different_industries
from object_rows
)
select
metric_number
as "Номер",
metric_name
as "Признак",
filled_count
as "Заполнено_объектов",
denominator
as "Всего_объектов",
round(
100.0 * filled_count / nullif(denominator, 0),
1
)
as "Заполненность_процентов"
from summary
cross join lateral (
values
(1, 'ИНН контрагента договора содержит цифры', with_inn_digits, total_objects),
(2, 'ИНН после очистки имеет длину 10 или 12', with_inn_valid_length, total_objects),
(3, 'ИНН длины 10 или 12 в неудаленной записи контрагента', with_inn_valid_length_live_record, total_objects),
(4, 'Нормализованный адрес', with_normalized_address, total_objects),
(5, 'Адрес как его ввели', with_original_address, total_objects),
(6, 'Хотя бы один адрес', with_any_address, total_objects),
(7, 'Код ФИАС', with_fias, total_objects),
(8, 'Широта и долгота', with_coordinates, total_objects),
(9, 'ID адреса 2ГИС', with_dgis_id, total_objects),
(10, 'Описание объекта', with_description, total_objects),
(11, 'Непустой JSON-объект характеристик', with_nonempty_json_object, total_objects),
(12, 'Площадь в JSON как непустой текст', with_area, total_objects),
(13, 'Год постройки в JSON как непустой текст', with_construction_year, total_objects),
(14, 'Материал несущих стен в JSON', with_wall_material, total_objects),
(15, 'Отрасль из CRM', with_crm_industry, total_objects),
(16, 'Отрасль из неудаленной записи CRM', with_crm_industry_live_record, total_objects),
(17, 'Отрасль из задачи', with_task_industry, total_objects),
(18, 'Хотя бы одна отрасль', with_any_industry, total_objects),
(19, 'Обе отрасли заполнены, но текст различается', with_different_industries, total_objects)
) as metrics(
metric_number,
metric_name,
filled_count,
denominator
)
order by metric_number;


/* ========================================================================
ЗАПРОС 5 ИЗ 5. КАНДИДАТЫ НА ЦЕЛЕВУЮ СТОИМОСТЬ

Запрос ничего не назначает целевой переменной и не сравнивает размеры сумм.
Он проверяет покрытие четырех разных денежных показателей:
- страховую стоимость объекта;
- страховую сумму из связи задача-объект;
- залоговую стоимость для объектов с признаком залога;
- наличие хотя бы одной страховой суммы в вариантах условий.

У всех показателей единица результата — техническая объектная строка после
выбора одной связи на пару задача + object_id. Варианты условий предварительно
агрегируются до этой же единицы и поэтому не размножают объекты.

В словаре нет отдельной валюты залоговой стоимости. Поэтому для этого
показателя наличие валюты всегда будет равно нулю. Это ограничение схемы,
а не обычный пропуск пользователя.

Распределения сумм здесь намеренно не считаются: сначала нужно выбрать
правильный показатель, проверить валюты, годы и смысл поля.
======================================================================== */

with task_candidates as (
select
c.id as contract_id,
extract(year from c.d_start_contract)::integer as contract_start_year,
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
contract_id,
contract_start_year,
task_id
from task_candidates
where task_rank = 1
),
eligible_tasks as (
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
object_candidates as (
select
task.contract_id,
task.contract_start_year,
task.task_id,
obj.id as object_id,
tobj.id as task_object_link_id,
tobj.characteristics_id,
tobj.insured_sum as object_insured_sum,
tobj.insured_sum_currency as object_insured_sum_currency,
ch.insurance_value,
ch.insurance_value_currency,
ch.insurance_value_basis,
ch.is_pledged,
ch.pledged_value,
row_number() over (
partition by task.task_id, obj.id
order by
tobj.d_change desc nulls last,
tobj.d_create desc nulls last,
ch.version_start_date desc nulls last,
ch.version_number desc nulls last,
tobj.id desc,
ch.id desc
) as object_rank
from eligible_tasks task
join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = task.task_id
join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
join base_insurance_object obj
on obj.id = ch.insurance_object_id
where obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
),
object_rows as (
select *
from object_candidates
where object_rank = 1
),
selected_characteristics as (
select distinct
characteristics_id
from object_rows
),
condition_profile as (
select
selected.characteristics_id,
count(cond.id) as condition_row_count,
count(cond.insured_sum) as condition_amount_count,
coalesce(
bool_or(cond.insured_sum = 0),
false
) as condition_has_zero,
coalesce(
bool_or(cond.insured_sum < 0),
false
) as condition_has_negative,
coalesce(
bool_or(nullif(btrim(cond.insured_sum_currency), '') is not null),
false
) as condition_has_currency,
count(distinct cond.insured_sum) filter (
where cond.insured_sum is not null
) as condition_distinct_amount_count,
count(distinct upper(btrim(cond.insured_sum_currency))) filter (
where nullif(btrim(cond.insured_sum_currency), '') is not null
) as condition_distinct_currency_count
from selected_characteristics selected
left join base_insurance_object_conditions cond
on cond.characteristics_id = selected.characteristics_id
group by selected.characteristics_id
),
object_measure_source as (
select
object_row.*,
condition_data.condition_row_count,
condition_data.condition_amount_count,
condition_data.condition_has_zero,
condition_data.condition_has_negative,
condition_data.condition_has_currency,
condition_data.condition_distinct_amount_count,
condition_data.condition_distinct_currency_count
from object_rows object_row
join condition_profile condition_data
on condition_data.characteristics_id = object_row.characteristics_id
),
metric_rows as (
select
object_row.contract_id,
object_row.task_id,
object_row.object_id,
object_row.contract_start_year,
metric.metric_number,
metric.metric_name,
metric.is_applicable,
metric.has_source_row,
metric.is_filled,
metric.has_zero,
metric.has_negative,
metric.has_currency,
metric.has_basis,
metric.has_multiple_values,
metric.has_multiple_currencies
from object_measure_source object_row
cross join lateral (
values
(
1,
'Страховая стоимость объекта',
true,
true,
object_row.insurance_value is not null,
object_row.insurance_value = 0,
object_row.insurance_value < 0,
nullif(btrim(object_row.insurance_value_currency), '') is not null,
nullif(btrim(object_row.insurance_value_basis), '') is not null,
false,
false
),
(
2,
'Страховая сумма из связи задача-объект',
true,
true,
object_row.object_insured_sum is not null,
object_row.object_insured_sum = 0,
object_row.object_insured_sum < 0,
nullif(btrim(object_row.object_insured_sum_currency), '') is not null,
false,
false,
false
),
(
3,
'Залоговая стоимость при is_pledged = true',
object_row.is_pledged is true,
true,
object_row.pledged_value is not null,
object_row.pledged_value = 0,
object_row.pledged_value < 0,
false,
false,
false,
false
),
(
4,
'Страховая сумма из вариантов условий',
true,
object_row.condition_row_count > 0,
object_row.condition_amount_count > 0,
object_row.condition_has_zero,
object_row.condition_has_negative,
object_row.condition_has_currency,
false,
object_row.condition_distinct_amount_count > 1,
object_row.condition_distinct_currency_count > 1
),
(
5,
'Контроль: pledged_value заполнена при is_pledged не TRUE',
object_row.is_pledged is not true,
true,
object_row.pledged_value is not null,
object_row.pledged_value = 0,
object_row.pledged_value < 0,
false,
false,
false,
false
)
) as metric(
metric_number,
metric_name,
is_applicable,
has_source_row,
is_filled,
has_zero,
has_negative,
has_currency,
has_basis,
has_multiple_values,
has_multiple_currencies
)
),
analysis_rows as (
select
metric.*,
'[ВСЕ ГОДЫ]' as year_group,
0 as scope_order,
null::integer as year_sort
from metric_rows metric

union all

select
metric.*,
coalesce(
metric.contract_start_year::text,
'[ГОД НЕ ЗАПОЛНЕН]'
) as year_group,
1 as scope_order,
metric.contract_start_year as year_sort
from metric_rows metric
)
select
metric_number
as "Номер",
metric_name
as "Денежный_показатель",
year_group
as "Год_начала_договора",
count(*) filter (
where is_applicable
)
as "Объектов_в_знаменателе",
count(*) filter (
where is_applicable
and has_source_row
)
as "Объектов_со_строкой_источника",
count(*) filter (
where is_applicable
and is_filled
)
as "Объектов_с_заполненной_суммой",
round(
100.0 * count(*) filter (
where is_applicable
and is_filled
) / nullif(
count(*) filter (
where is_applicable
),
0
),
1
)
as "Заполненность_процентов",
count(*) filter (
where is_applicable
and has_zero
)
as "Объектов_с_нулем",
count(*) filter (
where is_applicable
and has_negative
)
as "Объектов_с_отрицательным_значением",
count(*) filter (
where is_applicable
and has_currency
)
as "Объектов_с_валютой",
count(*) filter (
where is_applicable
and has_basis
)
as "Объектов_с_основанием_стоимости",
count(*) filter (
where is_applicable
and has_multiple_values
)
as "Объектов_с_несколькими_значениями",
count(*) filter (
where is_applicable
and has_multiple_currencies
)
as "Объектов_с_несколькими_валютами"
from analysis_rows
group by
metric_number,
metric_name,
year_group,
scope_order,
year_sort
order by
metric_number,
scope_order,
year_sort desc nulls last;
