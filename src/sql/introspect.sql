SELECT c.oid, ns.nspname AS table_schema, c.relname AS table_name
FROM pg_namespace ns
JOIN pg_class c ON ns.oid = c.relnamespace
LEFT JOIN (pg_type t
JOIN pg_namespace nt ON t.typnamespace = nt.oid) ON c.reloftype = t.oid
WHERE c.relkind = ANY('{r,m,v}'::char[])
AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
AND c.relname NOT LIKE 'pg_%'

WITH tables AS (
  SELECT c.oid, ns.nspname AS table_schema, c.relname AS table_name
  FROM pg_namespace ns
  JOIN pg_class c ON ns.oid = c.relnamespace
  LEFT JOIN (pg_type t
  JOIN pg_namespace nt ON t.typnamespace = nt.oid) ON c.reloftype = t.oid
  WHERE c.relkind = ANY('{r,m,v}'::char[])
  AND ns.nspname NOT IN ('pg_catalog', 'information_schema')
  AND c.relname NOT LIKE 'pg_%'
), cols AS (
  SELECT tab.oid,
  ARRAY[tab.oid::int, a.attnum::int] AS colid,
  quote_ident(tab.table_schema) || '.' ||
    quote_ident(tab.table_name) || '.' ||
    quote_ident(a.attname) AS fullcolname,
  tab.table_schema,
  tab.table_name,
  a.attname AS column_name,
  a.attnum,
  e.allowed,
  NOT a.attnotnull AS is_nullable,
  format_type(a.atttypid, a.atttypmod) AS data_type,
  CASE
    WHEN t.typelem <> 0::oid AND t.typlen = '-1'::integer THEN 'array'
    WHEN e.allowed IS NOT NULL THEN 'enum'
    WHEN nt.nspname = 'pg_catalog'::name THEN format_type(a.atttypid, NULL::integer)
    WHEN t.typname IS NOT NULL AND nt.nspname IS NOT NULL THEN quote_ident(nt.nspname) || '.' || quote_ident(t.typname)
    ELSE 'unknown'
  END::text AS base_data_type
  FROM pg_catalog.pg_attribute a
  JOIN tables tab ON a.attrelid = tab.oid
  JOIN (pg_type t JOIN pg_namespace nt ON t.typnamespace = nt.oid) ON a.atttypid = t.oid
  LEFT JOIN (
    SELECT enumtypid, array_agg(enumlabel ORDER by enumsortorder) AS allowed
    FROM pg_enum
    GROUP by 1
  ) e ON enumtypid=atttypid
  WHERE NOT a.attisdropped AND a.attnum > 0
), pkeys AS (
  SELECT p.attrelid AS oid,
  ARRAY[p.attrelid::int, a.attnum::int] AS colid,
  array_agg(ARRAY[p.attrelid::int, a.attnum::int]) OVER (partition by p.attrelid) AS pkey,
  array_agg(a.attname) OVER (partition by p.attrelid) AS pkey_cols
  FROM (
     SELECT c.conrelid AS attrelid, unnest(c.conkey) AS attnum
     FROM pg_catalog.pg_constraint c
     WHERE c.contype = 'p'
  ) p
  JOIN pg_catalog.pg_attribute a USING(attrelid, attnum)
  WHERE NOT a.attisdropped
), simply_indexed AS (
SELECT
colid,
array_agg(index_name) AS index_names
FROM 
(SELECT ARRAY[ix.indrelid::int, a.attnum::int] AS colid,
  i.relname AS index_name
  FROM pg_index ix
  JOIN pg_class i ON i.oid = ix.indexrelid
  JOIN pg_attribute a ON a.attrelid = ix.indrelid
  WHERE array_length(ix.indkey, 1) = 1 AND a.attnum = ANY(ix.indkey)
  ) t
GROUP by 1
), cons AS (
  SELECT
    fcol.colid AS fdep,
    tcol.colid AS tdep,
    array_agg(fcol.colid) OVER (partition by c.oid) AS fdeps,
    array_agg(tcol.colid) OVER (partition by c.oid) AS tdeps
  FROM pg_catalog.pg_constraint c
  JOIN cols fcol ON fcol.oid=c.confrelid AND fcol.attnum = ANY(confkey)
  JOIN cols tcol ON tcol.oid=c.conrelid AND tcol.attnum = ANY(conkey)
  WHERE c.contype = 'f'
), rdeps AS (
  SELECT c.colid,
    f.fdeps AS dep_to,
    array_agg(f.tdeps) AS dependents
  FROM cons f
  JOIN cols c ON c.colid = f.fdep
  GROUP by 1, 2
), deps AS (
  SELECT c.colid,
    t.tdeps AS dep_from,
    array_agg(t.fdeps) AS dependencies
  FROM cons t
  JOIN cols c ON c.colid = t.tdep
  GROUP by 1, 2
)
SELECT c.*,
pkey,
dep_from, dependencies,
dep_to, dependents,
index_names
FROM cols c
LEFT JOIN deps USING(colid)
LEFT JOIN rdeps USING(colid)
LEFT JOIN pkeys USING(colid)
LEFT JOIN simply_indexed USING(colid)
;

select 
