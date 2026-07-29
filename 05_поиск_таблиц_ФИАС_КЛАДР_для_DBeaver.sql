select
n.nspname as schema_name,
c.relname as table_name,
a.attname as column_name,
pg_catalog.format_type(a.atttypid, a.atttypmod) as data_type,
coalesce(d.description, '') as column_comment
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n
on n.oid = c.relnamespace
join pg_catalog.pg_attribute a
on a.attrelid = c.oid
left join pg_catalog.pg_description d
on d.objoid = c.oid
and d.objsubid = a.attnum
where c.relkind in ('r', 'p', 'v', 'm', 'f')
and a.attnum > 0
and not a.attisdropped
and n.nspname not in ('pg_catalog', 'information_schema')
and pg_catalog.has_table_privilege(c.oid, 'SELECT')
and (
lower(c.relname) like '%fias%'
or lower(c.relname) like '%kladr%'
or lower(c.relname) like '%address%'
or lower(c.relname) like '%addr%'
or lower(c.relname) like '%geo%'
or lower(a.attname) like '%fias%'
or lower(a.attname) like '%kladr%'
or lower(a.attname) like '%address%'
or lower(a.attname) like '%addr%'
or lower(a.attname) in (
'aoguid',
'houseguid',
'roomguid',
'steadguid',
'objectguid'
)
or lower(coalesce(d.description, '')) like '%фиас%'
or lower(coalesce(d.description, '')) like '%кладр%'
or lower(coalesce(d.description, '')) like '%адрес%'
)
order by
n.nspname,
c.relname,
a.attnum;
