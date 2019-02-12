with tables as (
  select c.oid, ns.nspname as table_schema, c.relname as table_name
  from pg_namespace ns
  join pg_class c on ns.oid = c.relnamespace
  left join (pg_type t
  join pg_namespace nt on t.typnamespace = nt.oid) on c.reloftype = t.oid
  where c.relkind = any('{r,m,v}'::char[])
  and ns.nspname not in ('pg_catalog', 'information_schema')
  and c.relname not like 'pg_%'
), cols as (
  select tab.oid,
  ARRAY[tab.oid::int, a.attnum::int] as colid,
  quote_ident(tab.table_schema) || '.' ||
    quote_ident(tab.table_name) || '.' ||
    quote_ident(a.attname) as fullcolname,
  tab.table_schema,
  tab.table_name,
  a.attname as column_name,
  a.attnum,
  e.allowed,
  not a.attnotnull as is_nullable,
  format_type(a.atttypid, a.atttypmod) as data_type,
  case
    when t.typelem <> 0::oid and t.typlen = '-1'::integer then 'array'
    when e.allowed is not null then 'enum'
    when nt.nspname = 'pg_catalog'::name then format_type(a.atttypid, null::integer)
    when t.typname is not null and nt.nspname is not null then quote_ident(nt.nspname) || '.' || quote_ident(t.typname)
    else 'unknown'
  end::text as base_data_type,
  information_schema._pg_char_max_length(information_schema._pg_truetypid(a.*, t.*), information_schema._pg_truetypmod(a.*, t.*)) as character_maximum_length,
  information_schema._pg_numeric_precision(information_schema._pg_truetypid(a.*, t.*), information_schema._pg_truetypmod(a.*, t.*)) AS numeric_precision,
  information_schema._pg_numeric_scale(information_schema._pg_truetypid(a.*, t.*), information_schema._pg_truetypmod(a.*, t.*)) AS numeric_scale,
  pg_get_expr(ad.adbin, ad.adrelid) AS column_default
  from pg_catalog.pg_attribute a
  join tables tab on a.attrelid = tab.oid
  join (pg_type t join pg_namespace nt on t.typnamespace = nt.oid) on a.atttypid = t.oid
  left join pg_attrdef ad on a.attrelid = ad.adrelid and a.attnum = ad.adnum
  left join (
    select enumtypid, array_agg(enumlabel order by enumsortorder) as allowed
    from pg_enum
    group by 1
  ) e on enumtypid=atttypid
  where not a.attisdropped and a.attnum > 0
), pkeys as (
  select p.attrelid as oid,
  ARRAY[p.attrelid::int, a.attnum::int] as colid,
  array_agg(ARRAY[p.attrelid::int, a.attnum::int]) over (partition by p.attrelid) as pkey,
  array_agg(a.attname) over (partition by p.attrelid) as pkey_cols
  from (
     select c.conrelid as attrelid, unnest(c.conkey) as attnum
     from pg_catalog.pg_constraint c
     where c.contype = 'p'
  ) p
  join pg_catalog.pg_attribute a using(attrelid, attnum)
  where not a.attisdropped
), simply_indexed as (
select
colid,
array_agg(index_name) as index_names
from 
(select ARRAY[ix.indrelid::int, a.attnum::int] as colid,
  i.relname as index_name
  from pg_index ix
  join pg_class i on i.oid = ix.indexrelid
  join pg_attribute a on a.attrelid = ix.indrelid
  where array_length(ix.indkey, 1) = 1 and a.attnum = ANY(ix.indkey)
  ) t
group by 1
), cons as (
  select
    fcol.colid as fdep,
    tcol.colid as tdep,
    array_agg(fcol.colid) over (partition by c.oid) as fdeps,
    array_agg(tcol.colid) over (partition by c.oid) as tdeps
  from pg_catalog.pg_constraint c
  join cols fcol on fcol.oid=c.confrelid and fcol.attnum = any(confkey)
  join cols tcol on tcol.oid=c.conrelid and tcol.attnum = any(conkey)
  where c.contype = 'f'
), rdeps as (
  select c.colid,
    f.fdeps as dep_to,
    array_agg(f.tdeps) as dependents
  from cons f
  join cols c on c.colid = f.fdep
  group by 1, 2
), deps as (
  select c.colid,
    t.tdeps as dep_from,
    array_agg(t.fdeps) as dependencies
  from cons t
  join cols c on c.colid = t.tdep
  group by 1, 2
)
select c.*,
pkey,
dep_from, dependencies,
dep_to, dependents,
index_names
from cols c
left join deps using(colid)
left join rdeps using(colid)
left join pkeys using(colid)
left join simply_indexed using(colid)
;
