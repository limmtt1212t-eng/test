/*
ЗАПУСКАТЬ В DBeaver В ПОДКЛЮЧЕНИИ К "СФЕРЕ".

Назначение:
показать все таблицы, представления и колонки, которые доступны текущему
пользователю на чтение.

Одна строка результата = одна колонка одной таблицы или представления.

Запрос читает только системное описание структуры базы. Данные из рабочих
таблиц он не читает и ничего в базе не изменяет.
*/

select
n.nspname as "SCHEMA_NAME",
c.relname as "TABLE_NAME",
case c.relkind
when 'r' then 'TABLE'
when 'p' then 'PARTITIONED TABLE'
when 'v' then 'VIEW'
when 'm' then 'MATERIALIZED VIEW'
when 'f' then 'FOREIGN TABLE'
else c.relkind::text
end as "TABLE_TYPE",
pg_catalog.obj_description(c.oid, 'pg_class') as "TABLE_COMMENTS",
a.attnum as "COLUMN_ID",
a.attname as "COLUMN_NAME",
pg_catalog.format_type(a.atttypid, a.atttypmod) as "DATA_TYPE",
case
when a.attnotnull then 'N'
else 'Y'
end as "NULLABLE",
pg_catalog.pg_get_expr(ad.adbin, ad.adrelid) as "COLUMN_DEFAULT",
pg_catalog.col_description(c.oid, a.attnum) as "COLUMN_COMMENTS"
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n
on n.oid = c.relnamespace
join pg_catalog.pg_attribute a
on a.attrelid = c.oid
left join pg_catalog.pg_attrdef ad
on ad.adrelid = a.attrelid
and ad.adnum = a.attnum
where c.relkind in ('r', 'p', 'v', 'm', 'f')
and a.attnum > 0
and not a.attisdropped
and n.nspname not in ('pg_catalog', 'information_schema')
and n.nspname not like 'pg_toast%'
and n.nspname not like 'pg_temp_%'
and pg_catalog.has_table_privilege(c.oid, 'SELECT')
order by
n.nspname,
c.relname,
a.attnum;
