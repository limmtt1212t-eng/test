/*
ЗАПУСКАТЬ В ПОДКЛЮЧЕНИИ К КХД 1.0.

Синтаксис рассчитан на Oracle.
В файле пять независимых запросов. Запускать по одному.

Если появится ORA-00942, значит таблицы доступны через другую схему.
Тогда добавьте имя схемы, например:
DM_RISK_AVATAR.CONTRACTS

Не переходите к запросу 5, пока запросы 1-4 не подтвердят правильную связь.
*/


/* ======================================================================
ЗАПРОС 1 ИЗ 5. ПРОВЕРКА:
LNK_CLIENT_OBJECT_CONTRACT.OBJECT_ID -> ESTATE_OBJECTS.CAD_IND

Главный результат — столбцы "Объектов найдено в ESTATE_OBJECTS" и
"Объектов с кадастровым номером" по каждой OBJECT_CATEGORY.
====================================================================== */

select
coalesce(l.object_category, '[НЕ ЗАПОЛНЕНО]')
as "Категория объекта",
count(*) as "Строк связи",
count(distinct l.contract_id) as "Договоров",
count(distinct l.object_id) as "Уникальных OBJECT_ID",
count(distinct case
when e.cad_ind is not null then l.object_id
end) as "Объектов найдено в ESTATE_OBJECTS",
count(distinct case
when trim(e.cadaster) is not null then l.object_id
end) as "Объектов с кадастровым номером",
round(
100 * count(distinct case
when e.cad_ind is not null then l.object_id
end) / nullif(count(distinct l.object_id), 0),
1
) as "Покрытие ESTATE_OBJECTS процентов"
from lnk_client_object_contract l
left join estate_objects e
on e.cad_ind = case
when regexp_like(trim(l.object_id), '^[0-9]+$')
then to_number(trim(l.object_id))
end
group by
coalesce(l.object_category, '[НЕ ЗАПОЛНЕНО]')
order by
"Объектов найдено в ESTATE_OBJECTS" desc,
"Договоров" desc;


/* ======================================================================
ЗАПРОС 2 ИЗ 5. АЛЬТЕРНАТИВНАЯ ПРОВЕРКА:
CONTRACTS.OBJECT_ID -> ESTATE_OBJECTS.CAD_IND

Она нужна, потому что в CONTRACTS тоже есть поле OBJECT_ID.
Сравним этот путь с результатом запроса 1.
====================================================================== */

select
extract(
year from coalesce(c.contract_sign_date, c.liability_start_date)
) as "Год договора",
count(distinct c.contract_id) as "Договоров",
count(distinct case
when trim(c.object_id) is not null then c.contract_id
end) as "Договоров с OBJECT_ID",
count(distinct case
when e.cad_ind is not null then c.contract_id
end) as "Договоров найдено в ESTATE_OBJECTS",
count(distinct case
when trim(e.cadaster) is not null then c.contract_id
end) as "Договоров с кадастровым номером"
from contracts c
left join estate_objects e
on e.cad_ind = case
when regexp_like(trim(c.object_id), '^[0-9]+$')
then to_number(trim(c.object_id))
end
where coalesce(c.contract_sign_date, c.liability_start_date)
>= date '2023-01-01'
and coalesce(c.contract_sign_date, c.liability_start_date)
< date '2027-01-01'
group by
extract(
year from coalesce(c.contract_sign_date, c.liability_start_date)
)
order by
"Год договора" desc;


/* ======================================================================
ЗАПРОС 3 ИЗ 5. ПОЛНАЯ ЦЕПОЧКА КХД ПО ГОДУ, ПРОДУКТУ И КАТЕГОРИИ

Показывает:
CONTRACTS -> LNK_CLIENT_OBJECT_CONTRACT -> ESTATE_OBJECTS.

Строки результата разных категорий нельзя складывать: один договор может
содержать несколько объектов и категорий.
====================================================================== */

select
extract(
year from coalesce(c.contract_sign_date, c.liability_start_date)
) as "Год договора",
coalesce(c.product_group, '[НЕ ЗАПОЛНЕНО]')
as "Группа продукта",
coalesce(l.object_category, '[НЕ ЗАПОЛНЕНО]')
as "Категория объекта",
count(distinct c.contract_id) as "Договоров",
count(distinct l.object_id) as "OBJECT_ID в связях",
count(distinct e.cad_ind) as "Объектов ESTATE_OBJECTS",
count(distinct case
when trim(e.cadaster) is not null then e.cad_ind
end) as "Объектов с кадастровым номером",
count(distinct case
when e.square is not null then e.cad_ind
end) as "Объектов с площадью",
count(distinct case
when e.price is not null then e.cad_ind
end) as "Объектов с кадастровой стоимостью"
from contracts c
join lnk_client_object_contract l
on l.contract_id = c.contract_id
left join estate_objects e
on e.cad_ind = case
when regexp_like(trim(l.object_id), '^[0-9]+$')
then to_number(trim(l.object_id))
end
where coalesce(c.contract_sign_date, c.liability_start_date)
>= date '2023-01-01'
and coalesce(c.contract_sign_date, c.liability_start_date)
< date '2027-01-01'
group by
extract(
year from coalesce(c.contract_sign_date, c.liability_start_date)
),
coalesce(c.product_group, '[НЕ ЗАПОЛНЕНО]'),
coalesce(l.object_category, '[НЕ ЗАПОЛНЕНО]')
order by
"Год договора" desc,
"Объектов с кадастровым номером" desc,
"Договоров" desc;


/* ======================================================================
ЗАПРОС 4 ИЗ 5. ГОТОВАЯ ТАБЛИЦА POLICY_NUMBER -> CADASTER

Проверяет DICT_INS_POTENTIAL_OBJECT_ADDRESS_EXTRA.
Сначала нужно понять, есть ли в ней корпоративные имущественные продукты.
====================================================================== */

select
coalesce(product_group, '[НЕ ЗАПОЛНЕНО]') as "Группа продукта",
coalesce(object_type, '[НЕ ЗАПОЛНЕНО]') as "Тип объекта",
count(*) as "Строк",
count(distinct policy_id) as "Уникальных POLICY_ID",
count(distinct policy_number) as "Уникальных номеров полиса",
count(distinct case
when trim(cadaster) is not null then policy_id
end) as "POLICY_ID с кадастровым номером",
count(distinct case
when trim(cadaster) is not null then cadaster
end) as "Уникальных кадастровых номеров",
count(distinct case
when trim(fias_id) is not null then policy_id
end) as "POLICY_ID с ФИАС",
count(distinct case
when geo_latitude is not null
and geo_longitude is not null then policy_id
end) as "POLICY_ID с координатами"
from dict_ins_potential_object_address_extra
group by
coalesce(product_group, '[НЕ ЗАПОЛНЕНО]'),
coalesce(object_type, '[НЕ ЗАПОЛНЕНО]')
order by
"POLICY_ID с кадастровым номером" desc,
"Уникальных POLICY_ID" desc;


/* ======================================================================
ЗАПРОС 5 ИЗ 5. ШАБЛОН ДЛЯ КОНКРЕТНЫХ ДОГОВОРОВ "СФЕРЫ"

Пока WHERE 1 = 0, запрос безопасно возвращает ноль строк.

После запроса 1 из файла 04_СФЕРА_ключи_для_проверки_КХД.sql:

1. Возьмите сначала 10-20 непустых sbs_id.
2. Замените строку WHERE 1 = 0 на условие:

   where c.contract_id in (
   'первый_sbs_id',
   'второй_sbs_id'
   )

3. Если sbs_id не находится, используйте CONTRACT_NUM вместе с ИНН и датой.
====================================================================== */

select
c.contract_id as "КХД CONTRACT_ID",
c.contract_num as "КХД номер договора",
lc.inn as "КХД ИНН",
c.contract_sign_date as "КХД дата подписания",
c.liability_start_date as "КХД дата начала",
c.product_group as "КХД группа продукта",
l.object_category as "КХД категория объекта",
l.object_id as "КХД OBJECT_ID",
e.cad_ind as "ЕГРН CAD_IND",
e.cadaster as "Кадастровый номер",
e.address_name as "Адрес объекта КХД",
e.address_src as "Необработанный адрес объекта",
e.square as "Площадь ЕГРН",
e.measure as "Единица площади",
e.price as "Кадастровая стоимость",
e.object_type_rosreestr as "Тип объекта Росреестра",
e.oks_purpose as "Назначение объекта",
e.construction_complete_year as "Год завершения строительства",
e.comissioning_year as "Год ввода в эксплуатацию",
e.floor_capacity as "Этажность",
e.wall_material as "Материал стен"
from contracts c
left join legal_clients lc
on lc.client_id = c.client_id
left join lnk_client_object_contract l
on l.contract_id = c.contract_id
left join estate_objects e
on e.cad_ind = case
when regexp_like(trim(l.object_id), '^[0-9]+$')
then to_number(trim(l.object_id))
end
where 1 = 0
order by
c.contract_id,
e.cad_ind;
