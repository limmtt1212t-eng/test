/*
ЗАПУСКАТЬ ТОЛЬКО В КХД 1.0 (ORACLE).

Здесь 3 отдельных запроса.
Запускать их по одному, не все сразу.

Запросы ничего не изменяют.
Адреса остаются только на рабочем ноутбуке.
*/

/*
ЗАПРОС 1.
Как выглядит адрес в финальной таблице ЕГРН.
*/
select
e.egrn_address,
e.address_src,
e.postal_code,
e.region_type,
e.region,
e.city_type,
e.city,
e.settlement_type,
e.settlement,
e.street_type,
e.street,
e.house_number,
e.korpus,
e.stroenie,
e.fias_level,
e.fias_id_house
from dm_risk_avatar.egrn_data e
where e.egrn_address is not null
and rownum <= 20;

/*
ЗАПРОС 2.
Как выглядит уже обогащённый и разобранный адрес КХД.
*/
select
a.full_address,
a.postal_code,
a.region_type,
a.region,
a.city_type,
a.city,
a.settlement_type,
a.settlement,
a.street_type,
a.street,
a.house_number,
a.korpus,
a.stroenie,
a.fias_level,
a.fias_id
from dm_risk_avatar.stg_spravochnik_zud_objaddress a
where a.full_address is not null
and rownum <= 20;

/*
ЗАПРОС 3.
Как выглядит адрес в агрегированной таблице строений.
*/
select
b.address,
b.postal_code,
b.region_type,
b.region,
b.city_type,
b.city,
b.settlement_type,
b.settlement,
b.street_type,
b.street,
b.house_number,
b.korpus,
b.stroenie,
b.fias_level,
b.fias_id_house
from dm_risk_avatar.buildings b
where b.address is not null
and rownum <= 20;
