/*
Запускать в Oracle, в подключении к КХД.

Проверяем все объекты ЕГРН по адресу:
Москва, улица Народного Ополчения, дом 11.

Площадь не участвует в поиске.
Запрос ищет сначала дом, а затем показывает и здание, и находящиеся
по этому адресу квартиры, офисы, комнаты и помещения.
*/

select *
from (
    select
        e.cadaster
            as "Кадастровый номер",
        e.cad_ind
            as "Внутренний ID ЕГРН",
        e.egrn_address
            as "Полный адрес ЕГРН",
        e.region
            as "Регион",
        e.city
            as "Город",
        e.settlement
            as "Населённый пункт",
        e.street_type
            as "Тип улицы",
        e.street
            as "Улица",
        e.house_number
            as "Дом",
        e.korpus
            as "Корпус",
        e.stroenie
            as "Строение",
        e.flat
            as "Квартира",
        e.flat2
            as "Квартира 2",
        e.office
            as "Офис",
        e.office2
            as "Офис 2",
        e.room
            as "Комната",
        e.room2
            as "Комната 2",
        e.compartment1
            as "Помещение 1",
        e.compartment2
            as "Помещение 2",
        e.fias_id_house
            as "ФИАС дома",
        e.fias_id_flat
            as "ФИАС помещения",
        e.building_type
            as "Тип строения",
        e.building_object_type
            as "Тип объекта в строении",
        e.oks_type_full
            as "Полный тип и назначение ОКС",
        e.oks_type
            as "Тип ОКС",
        e.oks_purpose
            as "Назначение ОКС",
        e.square
            as "Площадь ЕГРН",
        e.measure
            as "Единица площади",
        e.price
            as "Кадастровая стоимость",
        e.object_status
            as "Статус объекта",
        e.row_update_date
            as "Дата обновления строки"
    from dm_risk_avatar.egrn_data e
    where (
        replace(upper(trim(e.city)), 'Ё', 'Е') = 'МОСКВА'
        or replace(upper(trim(e.settlement)), 'Ё', 'Е') = 'МОСКВА'
        or replace(upper(trim(e.region)), 'Ё', 'Е') = 'МОСКВА'
    )
      and replace(upper(trim(e.street)), 'Ё', 'Е') like '%НАРОД%ОПОЛЧ%'
      and regexp_replace(
          replace(upper(trim(e.house_number)), 'Ё', 'Е'),
          '[^0-9A-ZА-Я]+',
          ''
      ) = '11'
    order by
        case
            when e.flat is null
             and e.flat2 is null
             and e.office is null
             and e.office2 is null
             and e.room is null
             and e.room2 is null
             and e.compartment1 is null
             and e.compartment2 is null
                then 1
            else 2
        end,
        e.flat nulls last,
        e.office nulls last,
        e.room nulls last,
        e.compartment1 nulls last,
        e.cadaster
)
where rownum <= 500;
