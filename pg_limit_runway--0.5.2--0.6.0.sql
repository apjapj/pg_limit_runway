-- pg_limit_runway 0.5.2 -> 0.6.0
--
-- Adds limit_runway_unwatched(): the integer primary-key and unique-index columns that have no
-- sequence and no nextval() default, which 0.5.2 skipped in silence. Additive; no existing object
-- changes. The function is closed like the other readers.

\echo Use "ALTER EXTENSION pg_limit_runway UPDATE TO '0.6.0'" to load this file. \quit

CREATE FUNCTION @extschema@.limit_runway_unwatched()
RETURNS TABLE (
  object   text,
  key_kind text,
  coltype  text,
  reason   text
)
LANGUAGE sql STABLE
SET lock_timeout = '1s'
AS $$
  -- One row per integer column in a primary key or unique index. Included columns of a covering
  -- unique index are not key columns, hence the indnkeyatts bound; expression indexes are skipped
  -- because their key is not a column.
  WITH key_cols AS (
    SELECT con.conrelid, u.attnum,
           CASE con.contype WHEN 'p' THEN 'primary key' ELSE 'unique constraint' END AS key_kind
      FROM pg_constraint con, unnest(con.conkey) AS u(attnum)
     WHERE con.contype IN ('p', 'u')
    UNION ALL
    SELECT i.indrelid, k.attnum, 'unique index'
      FROM pg_index i
      CROSS JOIN LATERAL unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
     WHERE i.indisunique AND i.indpred IS NULL AND i.indexprs IS NULL
       AND k.ord <= i.indnkeyatts
  ),
  -- One row per column even when it is both a primary key and a separate unique index.
  cols AS (
    SELECT DISTINCT ON (conrelid, attnum) conrelid, attnum, key_kind
      FROM key_cols
     ORDER BY conrelid, attnum, (key_kind = 'primary key') DESC, key_kind
  )
  SELECT format('%I.%I.%I', n.nspname, c.relname, a.attname),
         k.key_kind,
         format_type(a.atttypid, NULL),
         'no sequence; application-generated key, so there is no cheap position to sample'
    FROM cols k
    JOIN pg_class c     ON c.oid = k.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
   WHERE c.relkind IN ('r', 'p')
     AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
     AND a.atttypid IN ('int2'::regtype, 'int4'::regtype, 'int8'::regtype)
     AND a.attnum > 0 AND NOT a.attisdropped
     -- An owned sequence, including an identity column, is watched by limit_runway_sequences().
     AND NOT EXISTS (
       SELECT 1
         FROM pg_depend d
         JOIN pg_class sq ON sq.oid = d.objid AND sq.relkind = 'S'
        WHERE d.classid = 'pg_class'::regclass
          AND d.refclassid = 'pg_class'::regclass
          AND d.refobjid = c.oid AND d.refobjsubid = a.attnum
          AND d.deptype IN ('a', 'i'))
     -- A nextval() default has no dependency, but the sequence path already watches it.
     AND NOT EXISTS (
       SELECT 1 FROM pg_attrdef ad
        WHERE ad.adrelid = c.oid AND ad.adnum = a.attnum
          AND pg_get_expr(ad.adbin, ad.adrelid) ILIKE 'nextval(%')
   ORDER BY 1, 2
$$;

COMMENT ON FUNCTION @extschema@.limit_runway_unwatched() IS
  'Integer columns in a primary key or unique index that have no sequence and no nextval() default: '
  'the keys limit_runway does not watch, with the key kind and why. Catalog only; no table is read.';

REVOKE EXECUTE ON FUNCTION @extschema@.limit_runway_unwatched() FROM PUBLIC;
