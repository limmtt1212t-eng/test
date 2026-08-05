/*
ЗАПУСКАТЬ В DBeaver В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Цель:
разложить полный адрес объекта из "Сферы" на поля, сопоставимые с
адресными полями DM_RISK_AVATAR.BUILDINGS.

Единица результата:
одна строка = один объект недвижимости в последней подходящей задаче договора.

Важно:
1. PARSED_* и *_HINT — вычисленные поля. Их нужно проверять по исходному адресу.
2. SPHERE_* — исходные значения из "Сферы"; они не изменяются.
3. FIAS_ID_HOUSE и CADASTER запрос не придумывает. Их можно получить только
   после сопоставления результата с BUILDINGS.
4. Запрос ничего не меняет в базе.
*/

with task_candidates as (
select
c.id as contract_id,
c.n_contract,
coalesce(
t.d_conclusion_ins_contract::timestamp with time zone,
c.d_sign_contract,
t.d_create
) as as_of_date,
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
n_contract,
as_of_date,
task_id
from task_candidates
where task_rank = 1
),

object_candidates as (
select
task.contract_id,
task.n_contract,
task.as_of_date,
task.task_id,
obj.id as object_id,
obj.description as object_description,
obj.obj_type,
obj.elementary_obj_type,
obj.original_address,
geo.full_address,
geo.postal_code,
geo.area_type,
geo.area,
geo.settlement_type,
geo.settlement,
geo.street_type,
geo.street,
geo.house,
geo.building,
geo.block,
geo.flat,
geo.office,
geo.fias_code,
geo.latitude,
geo.longitude,
geo.address_dgis_id,
ch.characteristics,
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
from selected_tasks task
join bps_request_ins_task_insurance_object tobj
on tobj.parent_id = task.task_id
join base_insurance_object_characteristics ch
on ch.id = tobj.characteristics_id
join base_insurance_object obj
on obj.id = ch.insurance_object_id
left join base_geo_address geo
on geo.id = obj.geo_address_id
where obj.elementary_obj_type = 'nedv_ul_and_ip'
and obj.d_delete is null
),

one_row_per_object as (
select *
from object_candidates
where object_rank = 1
),

address_source as (
select
object_row.*,
coalesce(
nullif(btrim(object_row.full_address), ''),
nullif(btrim(object_row.original_address), '')
) as source_address
from one_row_per_object object_row
),

address_normalized as (
select
address_source.*,
btrim(
regexp_replace(
regexp_replace(
regexp_replace(
regexp_replace(
lower(
replace(
replace(coalesce(source_address, ''), chr(160), ' '),
'ё',
'е'
)
),
'[;|]+',
',',
'g'
),
'[.]',
' ',
'g'
),
'[[:space:]]+',
' ',
'g'
),
'[[:space:]]*,[[:space:]]*',
', ',
'g'
)
) as address_lower
from address_source
),

address_parsed as (
select
address_normalized.*,

coalesce(
nullif(btrim(postal_code), ''),
(regexp_match(address_lower, '([0-9]{6})'))[1]
) as parsed_postal_code,

case
when address_lower ~ '(^|, )[^,]+ (область|обл)(,|$)' then 'обл'
when address_lower ~ '(^|, )[^,]+ край(,|$)' then 'край'
when address_lower ~ '(^|, )[^,]+ (республика|респ)(,|$)' then 'респ'
when address_lower ~ '(^|, )(область|обл|край|республика|респ) ' then
case
when address_lower ~ '(^|, )(область|обл) ' then 'обл'
when address_lower ~ '(^|, )край ' then 'край'
else 'респ'
end
else null
end as parsed_region_type,

coalesce(
(regexp_match(address_lower, '(?:^|, )([^,]+?) (?:область|обл|край|республика|респ)(?:,|$)'))[1],
(regexp_match(address_lower, '(?:^|, )(?:область|обл|край|республика|респ) ([^,]+)(?:,|$)'))[1]
) as parsed_region,

coalesce(
nullif(btrim(area_type), ''),
case
when address_lower ~ '(?:^|, )[^,]+ (?:р-н|район)(?:,|$)' then 'р-н'
when address_lower ~ '(?:^|, )(?:р-н|район) ' then 'р-н'
else null
end
) as parsed_rayon_type,

coalesce(
nullif(btrim(area), ''),
(regexp_match(address_lower, '(?:^|, )([^,]+?) (?:р-н|район)(?:,|$)'))[1],
(regexp_match(address_lower, '(?:^|, )(?:р-н|район) ([^,]+)(?:,|$)'))[1]
) as parsed_rayon,

case
when address_lower ~ '(?:^|, )(?:г|город) ' then 'г'
else null
end as parsed_city_type,

(regexp_match(address_lower, '(?:^|, )(?:г|город) ([^,]+)(?:,|$)'))[1]
as parsed_city,

coalesce(
nullif(btrim(settlement_type), ''),
case
when address_lower ~ '(?:^|, )(?:пгт|поселок городского типа) ' then 'пгт'
when address_lower ~ '(?:^|, )(?:рп|рабочий поселок) ' then 'рп'
when address_lower ~ '(?:^|, )(?:пос|поселок) ' then 'п'
when address_lower ~ '(?:^|, )(?:с|село) ' then 'с'
when address_lower ~ '(?:^|, )(?:д|деревня) ' then 'д'
else null
end
) as parsed_settlement_type,

coalesce(
nullif(btrim(settlement), ''),
(regexp_match(address_lower, '(?:^|, )(?:пгт|поселок городского типа|рп|рабочий поселок|пос|поселок|с|село|д|деревня) ([^,]+)(?:,|$)'))[1]
) as parsed_settlement,

coalesce(
nullif(btrim(street_type), ''),
case
when address_lower ~ '(?:^|, )(?:ул|улица) ' then 'ул'
when address_lower ~ '(?:^|, )(?:пр-кт|проспект) ' then 'пр-кт'
when address_lower ~ '(?:^|, )(?:пер|переулок) ' then 'пер'
when address_lower ~ '(?:^|, )(?:ш|шоссе) ' then 'ш'
when address_lower ~ '(?:^|, )(?:наб|набережная) ' then 'наб'
when address_lower ~ '(?:^|, )(?:б-р|бульвар) ' then 'б-р'
when address_lower ~ '(?:^|, )проезд ' then 'проезд'
when address_lower ~ '(?:^|, )(?:пл|площадь) ' then 'пл'
when address_lower ~ '(?:^|, )тракт ' then 'тракт'
when address_lower ~ '(?:^|, )аллея ' then 'аллея'
else null
end
) as parsed_street_type,

coalesce(
nullif(btrim(street), ''),
(regexp_match(address_lower, '(?:^|, )(?:ул|улица|пр-кт|проспект|пер|переулок|ш|шоссе|наб|набережная|б-р|бульвар|проезд|пл|площадь|тракт|аллея) ([^,]+)(?:,|$)'))[1]
) as parsed_street,

coalesce(
nullif(btrim(house), ''),
(regexp_match(address_lower, '(?:^|, )(?:д|дом) *([0-9]+[а-яa-z]?(?:[/-][0-9а-яa-z]+)?)(?:,|$)'))[1]
) as parsed_house_number,

coalesce(
nullif(btrim(block), ''),
(regexp_match(address_lower, '(?:^|, )(?:корп|корпус|к) *([0-9а-яa-z/-]+)(?:,|$)'))[1]
) as parsed_korpus,

coalesce(
nullif(btrim(building), ''),
(regexp_match(address_lower, '(?:^|, )(?:стр|строение) *([0-9а-яa-z/-]+)(?:,|$)'))[1]
) as parsed_stroenie,

(regexp_match(address_lower, '(?:^|, )(?:вл|владение) *([0-9а-яa-z/-]+)(?:,|$)'))[1]
as parsed_vladenie,

btrim(
regexp_replace(
regexp_replace(
address_lower,
'[^0-9a-zа-я]+',
' ',
'g'
),
'[[:space:]]+',
' ',
'g'
)
) as normalized_address_for_matching

from address_normalized
),

result as (
select
contract_id,
n_contract,
as_of_date,
task_id,
object_id,
object_description,
obj_type,
elementary_obj_type,

original_address as sphere_original_address,
full_address as sphere_full_address,
source_address as address,
normalized_address_for_matching,

parsed_postal_code as parsed_postal_code,
parsed_region_type as parsed_region_type,
parsed_region as parsed_region,
parsed_rayon_type as parsed_rayon_type,
parsed_rayon as parsed_rayon,
parsed_city_type as parsed_city_type,
parsed_city as parsed_city,
parsed_settlement_type as parsed_settlement_type,
parsed_settlement as parsed_settlement,
parsed_street_type as parsed_street_type,
parsed_street as parsed_street,
parsed_house_number as parsed_house_number,
parsed_korpus as parsed_korpus,
parsed_stroenie as parsed_stroenie,
parsed_vladenie as parsed_vladenie,

flat as sphere_flat,
office as sphere_office,
fias_code as sphere_fias_code,
latitude as geo_latitude,
longitude as geo_longitude,
address_dgis_id as sphere_address_dgis_id,

case
when lower(coalesce(object_description, '')) like '%многоквартир%' then 'мкд'
when lower(coalesce(object_description, '')) like '%индивидуаль%жил%' then 'ижд'
when lower(coalesce(object_description, '')) like '%здани%'
or lower(coalesce(object_description, '')) like '%сооружен%'
or lower(coalesce(object_description, '')) like '%помещен%'
then 'прочие строения'
else null
end as building_type_hint,

case
when lower(coalesce(object_description, '')) like '%помещен%' then 'помещение'
when lower(coalesce(object_description, '')) like '%сооружен%' then 'сооружение'
when lower(coalesce(object_description, '')) like '%здани%' then 'здание'
else null
end as oks_type_hint,

case
when lower(coalesce(object_description, '')) like '%нежил%' then 'нежилое'
when lower(coalesce(object_description, '')) like '%жил%' then 'жилое'
when lower(coalesce(object_description, '')) like '%производ%' then 'производственное'
else null
end as oks_purpose_hint,

characteristics ->> 'construction_year' as sphere_construction_year,
characteristics ->> 'total_floors_count' as sphere_floor_capacity,
characteristics ->> 'load_bearing_walls_material' as sphere_wall_material,
characteristics ->> 'total_area_sq_m' as sphere_total_area_sq_m,

case
when source_address is null then 'NO_ADDRESS'
when parsed_street is not null
and parsed_house_number is not null then 'STREET_AND_HOUSE'
when parsed_city is not null
or parsed_settlement is not null then 'LOCALITY_ONLY'
else 'FULL_ADDRESS_ONLY'
end as parsed_address_quality,

'sphere_address_parser_v1' as parser_version

from address_parsed
)

select *
from result
order by
as_of_date desc nulls last,
contract_id,
object_id;
