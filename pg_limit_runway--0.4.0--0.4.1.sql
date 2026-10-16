-- pg_limit_runway--0.4.0--0.4.1.sql
--
-- 0.4.1 fixes one thing: limit_runway_command_row() quoted an already-quoted name a second time.
--
-- The finding's object is built by the finder with %I, so it arrives quoted. 0.4.0 split it on '.' and
-- applied %I to each part, so any name that needed quoting came back as """Mixed""" instead of
-- "Mixed": a statement naming an object that does not exist, which is the first rule of docs/act.md
-- broken. The replacement recovers the names with parse_ident(), which understands quoting and dots
-- inside a quoted name, and quotes each exactly once, the partition's date suffix inside the quotes.
-- The xid and multixact notes gain one clause: VACUUM cannot run inside a transaction block, so the
-- psql \gexec path must not be wrapped in BEGIN.
--
-- A SQL function's row type is part of its signature, and it does not change here, so this is a
-- CREATE OR REPLACE of one body: no DROP, and no grant taken with it. limit_runway_findings(), the
-- limit_runway view and limit_runway_text() are untouched and keep their grants. The comment and the
-- PUBLIC REVOKE are restated because CREATE OR REPLACE does not carry them.
--
-- Complain if this file is sourced in psql rather than loaded by ALTER EXTENSION, as every other
-- release and update script does.
\echo Use "ALTER EXTENSION pg_limit_runway UPDATE TO '0.4.1'" to load this file. \quit

CREATE OR REPLACE FUNCTION @extschema@.limit_runway_command_row(
  p_rank_class    integer,
  p_kind          text,
  p_object        text,
  p_until_date    timestamptz,
  p_from_date     timestamptz,
  p_used_fraction numeric)
RETURNS TABLE (
  tier    text,
  command text,
  note    text
)
LANGUAGE sql STABLE
AS $$
  WITH x AS (
    SELECT @extschema@.limit_runway_urgency(p_rank_class, p_until_date, p_used_fraction,
                                            interval '30 days') AS u
  )
  SELECT CASE WHEN x.u >= 6 THEN 'act' WHEN x.u >= 4 THEN 'schedule' ELSE 'plan' END AS tier,
         CASE p_kind
           WHEN 'sequence' THEN
             CASE WHEN coalesce(array_length(pi.parts, 1), 0) >= 3
                  THEN format('ALTER TABLE %I.%I ALTER COLUMN %I TYPE bigint;',
                              pi.parts[1], pi.parts[2], pi.parts[3])
                  ELSE format('ALTER SEQUENCE %I.%I AS bigint;', pi.parts[1], pi.parts[2]) END
           WHEN 'foreign key' THEN
             format('ALTER TABLE %I.%I ALTER COLUMN %I TYPE bigint;',
                    pi.parts[1], pi.parts[2], pi.parts[3])
           WHEN 'xid' THEN
             CASE WHEN p_object LIKE 'database %' THEN 'VACUUM (FREEZE);'
                  ELSE format('VACUUM (FREEZE) %s;', p_object) END
           WHEN 'multixact' THEN 'VACUUM (FREEZE);'
           WHEN 'partition' THEN
             -- FROM the last upper bound, TO the same plus the last partition's width, in the same
             -- schema as the parent. Named for the new lower bound's date, since the finding does not
             -- carry the last partition's name. The name is quoted once with the suffix inside the
             -- quotes, so a mixed-case table gets "Events Tbl_20260301" and not "Events Tbl"_20260301.
             format('CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L);',
                    pi.parts[1], pi.parts[2] || '_' || to_char(p_until_date, 'YYYYMMDD'),
                    pi.parts[1], pi.parts[2],
                    p_until_date, p_until_date + (p_until_date - p_from_date))
           WHEN 'replication slot' THEN format('SELECT pg_drop_replication_slot(%L);', p_object)
           WHEN 'connections' THEN
             'SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = ''client backend'' AND state = ''idle'' AND pid <> pg_backend_pid();'
           WHEN 'password' THEN
             format('ALTER ROLE %s VALID UNTIL %L;', substring(p_object from 6), now() + interval '1 year')
         END AS command,
         CASE p_kind
           WHEN 'sequence' THEN
             CASE WHEN coalesce(array_length(pi.parts, 1), 0) >= 3
                  THEN 'rewrites the whole table under ACCESS EXCLUSIVE; the only step that raises the column''s limit'
                  ELSE 'raises the sequence''s own ceiling; if a column fills it, that column is the real limit and must widen too' END
           WHEN 'foreign key' THEN 'rewrites the child table under ACCESS EXCLUSIVE; the parent key is already wide'
           WHEN 'xid' THEN
             CASE WHEN p_object LIKE 'database %'
                  THEN 'every table in the database; the least destructive step that lowers the age, and it is not cheap. Run it outside a transaction block'
                  ELSE 'freezes only rows past vacuum_freeze_min_age; it need not lower the age if the old rows are not yet eligible. Run it outside a transaction block' END
           WHEN 'multixact' THEN 'as the xid case: every table in the database, outside a transaction block. The member-space limit is not established, so it has no command'
           WHEN 'partition' THEN 'creates the next partition, its width the same as the last one''s; inserts for that range fail, or land in the DEFAULT, until it exists'
           WHEN 'replication slot' THEN 'the consumer must be rebuilt from a fresh base backup; the slot is already invalidated or about to be'
           WHEN 'connections' THEN 'frees idle client connections only; superusers are exempt from the limit, and busy sessions are left alone'
           WHEN 'password' THEN 'a new expiry date, never a password; a role whose logins do not use a password is unaffected'
         END AS note
    FROM x
    -- The names are recovered from the finding's object, which the finder already built with %I, and
    -- quoted once more below. CASE keeps parse_ident() lazy: it runs only for the kinds that split the
    -- object into names, so a slot name or a 'database xid' object is never handed to it.
    LEFT JOIN LATERAL (
      SELECT CASE WHEN p_kind IN ('sequence', 'foreign key', 'partition')
                  THEN parse_ident(p_object) END AS parts
    ) pi ON true
   -- No statement where the finding does not carry what it needs: a partition with no lower bound has
   -- no width, so it returns no row rather than a placeholder (docs/act.md, rule 1).
   WHERE CASE p_kind
           WHEN 'partition' THEN p_from_date IS NOT NULL AND p_until_date IS NOT NULL
           ELSE true
         END
$$;

COMMENT ON FUNCTION @extschema@.limit_runway_command_row(integer, text, text, timestamptz, timestamptz, numeric) IS
  'Internal: the tier, statement and cost for ONE finding, on the finding''s own fields, so a kind a '
  'test cannot build inside one transaction can still be pinned with a synthetic row. Not for callers; '
  'REVOKEd from PUBLIC. limit_runway_command() is the finding-shaped wrapper.';

REVOKE EXECUTE ON FUNCTION @extschema@.limit_runway_command_row(integer, text, text, timestamptz, timestamptz, numeric) FROM PUBLIC;
