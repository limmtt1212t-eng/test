/*
ЗАПУСКАТЬ В ORACLE, В ПОДКЛЮЧЕНИИ К КХД 1.0.

Цель запроса:
проверить простую цепочку

договор/полис -> кадастровый номер -> данные ЕГРН.

Используются только две таблицы:
1. DM_RISK_AVATAR.DICT_INS_POTENTIAL_OBJECT_ADDRESS_EXTRA
2. DM_RISK_AVATAR.EGRN_DATA

Запрос проверяет первые 1000 записей с кадастровым номером.
Он не выводит ФИО, дату рождения и другие персональные данные.
*/

with policies_sample as (
select
policy_id,
policy_number,
product_group,
object_type,
cadaster
from dm_risk_avatar.dict_ins_potential_object_address_extra
where trim(cadaster) is not null
and rownum <= 1000
)
select
count(distinct d.policy_id) as "Полисов в проверке",
count(distinct d.cadaster) as "Кадастровых номеров в проверке",
count(distinct case
when e.cadaster is not null then d.cadaster
end) as "Кадастровых номеров найдено в ЕГРН",
count(distinct case
when e.cadaster is not null then d.policy_id
end) as "Полисов найдено в ЕГРН",
round(
100 * count(distinct case
when e.cadaster is not null then d.cadaster
end) / nullif(count(distinct d.cadaster), 0),
1
) as "Процент кадастровых номеров найдено в ЕГРН"
from policies_sample d
left join dm_risk_avatar.egrn_data e
on trim(e.cadaster) = trim(d.cadaster);
