/* pg_limit_runway--0.1.sql
 *
 * What will break next: every hard limit the server can see, ordered as docs/ranking.md decides.
 * Current state only (README step 4): no history, so no rate and no projected date yet. Read-only.
 *
 *   limit_runway                       view: one row per limit worth reporting, most urgent first
 *   limit_runway_findings(min_used, date_window)   the same, with its thresholds as arguments
 *   limit_runway_text(...)             the sentence form
 *
 * Every rule below comes from a scenario in scenarios/, and the comments say which.
 */
\echo Use "CREATE EXTENSION pg_limit_runway" to load this file. \quit

DO $floor$
BEGIN
  IF current_setting('server_version_num')::int < 140000 THEN
    RAISE EXCEPTION 'pg_limit_runway needs PostgreSQL 14 or later; this is %', current_setting('server_version');
  END IF;
END
$floor$;

-- The order (docs/ranking.md): 1 failing now, 2 a date, 3 no rate yet (by share used), 4 peaks, 5 not
-- established. In 0.1 nothing has a projected date, because a date needs two samples (docs/rate.md); the
-- dates in class 2 are fixed ones, a password's expiry and a partition's last bound.
CREATE FUNCTION @extschema@.limit_runway_findings(min_used numeric DEFAULT 0.5,
                                                  date_window interval DEFAULT interval '30 days')
RETURNS TABLE (
  rank_class     int,
  rank_label     text,
  kind           text,
  object         text,
  current_value  numeric,
  limit_value    numeric,
  used_fraction  numeric,
  until_date     timestamptz,
  state          text,
  detail         text,
  "then"         text[],
  unknowns       text[]
)
LANGUAGE plpgsql STABLE
-- A monitor never waits behind a lock: a probe that cannot get one in time becomes "not established".
SET lock_timeout = '1s'
AS $fn$
DECLARE
  r          record;
  colmax     numeric;
  colmin     numeric;
  eff        numeric;
  cur        numeric;
  data_at    numeric;
  frac       numeric;
  th         text[];
  un         text[];
  lbl        text[] := ARRAY['failing now', 'date', 'no rate yet', 'peak', 'not established'];
  reserved   int;
  nfiles     bigint;
  hasrows    boolean;
  unread     text[] := '{}';
  noseq      text[] := '{}';
BEGIN
  -- ---------------------------------------------------------------- sequences tied to a column
  -- s1 to s3, s11, s12. The limit is the tighter of the sequence's own and the COLUMN's type, found
  -- through pg_depend (s1: a bigint sequence on an int4 column). A failed insert still consumes a value
  -- (s1), so a sequence can stand past the column's maximum: that is "exhausted", never a negative count.
  -- A sequence behind its data (s12) collides on the next default id: a state with a fix to run by hand,
  -- detected only through an index whose leading column is the column, never a scan.
  FOR r IN
    SELECT sn.nspname AS seq_schema, s.relname AS seq_name, sq.seqincrement AS inc, sq.seqmax, sq.seqmin,
           sq.seqcycle, sq.seqstart, tn.nspname AS tbl_schema, t.relname AS tbl_name, t.oid AS tbl_oid,
           a.attname, a.attnum, a.atttypid, format_type(a.atttypid, a.atttypmod) AS coltype,
           ps.last_value, has_sequence_privilege(s.oid, 'SELECT') AS can_read_seq
      FROM pg_class s
      JOIN pg_namespace sn  ON sn.oid = s.relnamespace
      JOIN pg_sequence sq   ON sq.seqrelid = s.oid
      LEFT JOIN pg_depend d ON d.objid = s.oid AND d.classid = 'pg_class'::regclass
                           AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
      LEFT JOIN pg_class t       ON t.oid = d.refobjid
      LEFT JOIN pg_namespace tn  ON tn.oid = t.relnamespace
      LEFT JOIN pg_attribute a   ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
      LEFT JOIN pg_sequences ps ON ps.schemaname = sn.nspname AND ps.sequencename = s.relname
     WHERE s.relkind = 'S' AND sn.nspname NOT IN ('pg_catalog', 'information_schema')
       AND NOT pg_is_other_temp_schema(sn.oid)
  LOOP
    th := '{}'; un := '{}';
    colmax := CASE r.atttypid WHEN 'int2'::regtype THEN 32767 WHEN 'int4'::regtype THEN 2147483647
                              WHEN 'int8'::regtype THEN 9223372036854775807 END;
    colmin := CASE r.atttypid WHEN 'int2'::regtype THEN -32768 WHEN 'int4'::regtype THEN -2147483648
                              WHEN 'int8'::regtype THEN -9223372036854775808 END;
    -- A sequence no column owns (s3_desc) is reported under its own name, against its own limits.
    kind := 'sequence';
    object := CASE WHEN r.attname IS NULL THEN format('%I.%I', r.seq_schema, r.seq_name)
                   ELSE format('%I.%I.%I', r.tbl_schema, r.tbl_name, r.attname) END;
    IF NOT r.can_read_seq THEN
      noseq := noseq || format('%I.%I', r.seq_schema, r.seq_name);   -- reported once below
      CONTINUE;
    END IF;
    -- Never called: nothing used yet, the position is one step before the start.
    cur := coalesce(r.last_value, r.seqstart - r.inc);
    IF r.inc > 0 THEN
      eff := least(r.seqmax, coalesce(colmax, r.seqmax));
      frac := (cur - r.seqmin) / nullif(eff - r.seqmin, 0);
    ELSE
      eff := greatest(r.seqmin, coalesce(colmin, r.seqmin));
      frac := (r.seqmax - cur) / nullif(r.seqmax - eff, 0);
    END IF;
    IF eff < coalesce(colmax, eff) AND r.inc > 0 AND NOT r.seqcycle THEN
      th := th || format('the limit is the sequence''s MAXVALUE %s, not the column''s %s', eff, r.coltype);
    END IF;

    -- The data: only through an index whose leading column is this one (s12), only for ascending.
    data_at := NULL;
    IF r.inc > 0 AND r.attname IS NOT NULL THEN
      IF EXISTS (SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
                   JOIN pg_am am ON am.oid = ic.relam
                  WHERE i.indrelid = r.tbl_oid AND i.indkey[0] = r.attnum AND am.amname = 'btree'
                    AND i.indpred IS NULL AND i.indisvalid) THEN
        IF has_table_privilege(r.tbl_oid, 'SELECT') AND has_schema_privilege(r.tbl_schema, 'USAGE') THEN
          -- The index's last entry: ORDER BY ... DESC LIMIT 1 reads one leaf page, however large the table.
          BEGIN
            EXECUTE format('SELECT %I::numeric FROM %I.%I WHERE %I IS NOT NULL ORDER BY %I DESC LIMIT 1',
                           r.attname, r.tbl_schema, r.tbl_name, r.attname, r.attname) INTO data_at;
          EXCEPTION WHEN lock_not_available THEN
            un := un || format('whether the sequence is behind the data is not established: %I.%I is locked', r.tbl_schema, r.tbl_name);
          END;
        ELSE
          un := un || format('whether the sequence is behind the data is not established: this role cannot read %I.%I', r.tbl_schema, r.tbl_name);
          unread := unread || object;
        END IF;
      ELSE
        un := un || format('whether the sequence is behind the data is not established: no btree index leads with %I, and the table is not scanned', r.attname);
      END IF;
    END IF;

    current_value := cur; limit_value := eff; until_date := NULL; "then" := th; unknowns := un;
    IF data_at IS NOT NULL AND data_at > cur THEN
      rank_class := 1; used_fraction := NULL;
      state := CASE WHEN r.seqcycle THEN 'cycled into existing keys' ELSE 'behind the data' END;
      detail := format('the sequence is behind the data (sequence at %s, data at %s): the next default id collides now. Fix, to run by hand: SELECT setval(%L, %s)',
                       cur, data_at, format('%I.%I', r.seq_schema, r.seq_name), data_at);
      rank_label := lbl[rank_class]; RETURN NEXT;
    ELSIF NOT r.seqcycle AND ((r.inc > 0 AND cur >= eff) OR (r.inc < 0 AND cur <= eff)) THEN
      rank_class := 1; used_fraction := NULL; state := 'exhausted';
      detail := format('%s (%s) is exhausted: the limit is %s%s', object, coalesce(r.coltype, 'sequence'), eff,
                       CASE WHEN (r.inc > 0 AND cur > eff) OR (r.inc < 0 AND cur < eff)
                            THEN format(', and the sequence stands past it at %s: failed inserts still consume values', cur) ELSE '' END);
      rank_label := lbl[rank_class]; RETURN NEXT;
    ELSIF frac >= min_used THEN
      rank_class := 3; used_fraction := round(frac, 4); state := 'no rate yet';
      detail := format('%s of %s values left (%s, %s)', abs(eff - cur),
                       CASE WHEN r.inc > 0 THEN eff - r.seqmin ELSE r.seqmax - eff END + 1, coalesce(r.coltype, 'sequence'),
                       CASE WHEN r.inc > 0 THEN 'ascending' ELSE 'descending' END);
      IF r.seqcycle THEN
        "then" := "then" || 'it cycles instead of failing: after the wrap, every insert collides with an existing key'::text;
      END IF;
      rank_label := lbl[rank_class]; RETURN NEXT;
    ELSIF r.attname IS NOT NULL AND r.inc > 0 AND NOT has_table_privilege(r.tbl_oid, 'SELECT') THEN
      NULL;   -- counted in unread, reported once below
    ELSIF cardinality(un) > 0 THEN
      -- Far from its limit, but whether it is behind its data could not be read: a gap, listed.
      rank_class := 5; used_fraction := NULL; state := 'not established';
      detail := un[1]; unknowns := un;
      rank_label := lbl[rank_class]; RETURN NEXT;
    END IF;
  END LOOP;
  -- One row for all the sequences, and one for all the columns, the role cannot read, rather than one
  -- each: each is one gap, in the grants.
  IF cardinality(noseq) > 0 THEN
    kind := 'sequence'; object := format('%s sequence(s) this role cannot read', cardinality(noseq));
    rank_class := 5; state := 'not established'; current_value := NULL; limit_value := NULL;
    used_fraction := NULL; until_date := NULL; "then" := '{}';
    detail := format('how close they are to their limits is not established: %s%s',
                     array_to_string(noseq[1:5], ', '), CASE WHEN cardinality(noseq) > 5 THEN ', ...' ELSE '' END);
    unknowns := ARRAY[detail];
    rank_label := lbl[rank_class]; RETURN NEXT;
  END IF;
  IF cardinality(unread) > 0 THEN
    kind := 'sequence'; object := format('%s column(s) this role cannot read', cardinality(unread));
    rank_class := 5; state := 'not established'; current_value := NULL; limit_value := NULL;
    used_fraction := NULL; until_date := NULL; "then" := '{}';
    detail := format('whether their sequences are behind the data is not established: %s%s',
                     array_to_string(unread[1:5], ', '), CASE WHEN cardinality(unread) > 5 THEN ', ...' ELSE '' END);
    unknowns := ARRAY[detail];
    rank_label := lbl[rank_class]; RETURN NEXT;
  END IF;

  -- ---------------------------------------------------------------- foreign keys narrower than the parent
  -- s4: the parent's sequence feeds a wider key; the child column runs out first.
  FOR r IN
    SELECT con.conname, cn.nspname AS child_schema, c.relname AS child_tbl, ca.attname AS child_col,
           ca.atttypid AS child_type, format_type(ca.atttypid, ca.atttypmod) AS child_coltype,
           pn.nspname AS par_schema, p.relname AS par_tbl, pa.attname AS par_col,
           format_type(pa.atttypid, pa.atttypmod) AS par_coltype, ps.last_value
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace cn ON cn.oid = c.relnamespace
      JOIN pg_class p ON p.oid = con.confrelid JOIN pg_namespace pn ON pn.oid = p.relnamespace
      JOIN pg_attribute ca ON ca.attrelid = con.conrelid AND ca.attnum = con.conkey[1]
      JOIN pg_attribute pa ON pa.attrelid = con.confrelid AND pa.attnum = con.confkey[1]
      JOIN pg_depend d ON d.refobjid = p.oid AND d.refobjsubid = pa.attnum AND d.deptype IN ('a', 'i')
                      AND d.classid = 'pg_class'::regclass
      JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
      JOIN pg_sequences ps ON ps.schemaname = (SELECT nspname FROM pg_namespace WHERE oid = s.relnamespace)
                          AND ps.sequencename = s.relname
     WHERE con.contype = 'f' AND cardinality(con.conkey) = 1
       AND ca.atttypid IN ('int2'::regtype, 'int4'::regtype)
       AND pa.atttypid IN ('int4'::regtype, 'int8'::regtype) AND ca.atttypid <> pa.atttypid
  LOOP
    colmax := CASE r.child_type WHEN 'int2'::regtype THEN 32767 ELSE 2147483647 END;
    kind := 'foreign key'; object := format('%I.%I.%I', r.child_schema, r.child_tbl, r.child_col);
    current_value := coalesce(r.last_value, 0); limit_value := colmax; until_date := NULL; unknowns := '{}';
    "then" := ARRAY[format('the limit is reached through the parent: %I.%I.%I is %s', r.par_schema, r.par_tbl, r.par_col, r.par_coltype)];
    IF coalesce(r.last_value, 0) > colmax THEN
      rank_class := 1; used_fraction := NULL; state := 'exhausted';
      detail := format('%s (%s) can no longer reference new rows of %I.%I: the parent key is at %s, past %s',
                       object, r.child_coltype, r.par_schema, r.par_tbl, r.last_value, colmax);
      rank_label := lbl[rank_class]; RETURN NEXT;
    ELSIF coalesce(r.last_value, 0) / colmax >= min_used THEN
      rank_class := 3; used_fraction := round(coalesce(r.last_value, 0) / colmax, 4); state := 'no rate yet';
      detail := format('%s of %s values left before %s (%s) cannot reference the parent', colmax - r.last_value, colmax, object, r.child_coltype);
      rank_label := lbl[rank_class]; RETURN NEXT;
    END IF;
  END LOOP;

  -- ---------------------------------------------------------------- transaction IDs and MultiXacts
  -- s5: read without assigning an xid. A forced vacuum need not lower the age, so the finding says so
  -- rather than promising the vacuum fixes it. Tables are listed only once past their own effective
  -- autovacuum_freeze_max_age; the database once past the server's.
  FOR r IN
    SELECT datname, age(datfrozenxid)::numeric AS xa, mxid_age(datminmxid)::numeric AS ma FROM pg_database WHERE datallowconn
  LOOP
    IF r.xa >= current_setting('autovacuum_freeze_max_age')::numeric THEN
      kind := 'xid'; object := format('database %I', r.datname); rank_class := 3;
      current_value := r.xa; limit_value := 2147483648; used_fraction := round(r.xa / 2147483648, 4);
      until_date := NULL; state := 'no rate yet'; unknowns := '{}';
      detail := format('xid age %s: past autovacuum_freeze_max_age %s; failsafe at %s; wraparound at 2147483648',
                       r.xa, current_setting('autovacuum_freeze_max_age'), current_setting('vacuum_failsafe_age'));
      "then" := ARRAY['a forced vacuum need not lower the age: it freezes only rows older than vacuum_freeze_min_age'];
      rank_label := lbl[rank_class]; RETURN NEXT;
    END IF;
    IF r.ma >= current_setting('autovacuum_multixact_freeze_max_age')::numeric THEN
      kind := 'multixact'; object := format('database %I', r.datname); rank_class := 3;
      current_value := r.ma; limit_value := 2147483648; used_fraction := round(r.ma / 2147483648, 4);
      until_date := NULL; state := 'no rate yet'; unknowns := '{}'; "then" := '{}';
      detail := format('multixact age %s: past autovacuum_multixact_freeze_max_age %s', r.ma, current_setting('autovacuum_multixact_freeze_max_age'));
      rank_label := lbl[rank_class]; RETURN NEXT;
    END IF;
  END LOOP;
  FOR r IN
    SELECT n.nspname, c.relname, age(c.relfrozenxid)::numeric AS xa,
           coalesce((SELECT option_value::numeric FROM pg_options_to_table(c.reloptions) WHERE option_name = 'autovacuum_freeze_max_age'),
                    current_setting('autovacuum_freeze_max_age')::numeric) AS fmax
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r', 'm', 't') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND c.relfrozenxid <> '0'::xid
  LOOP
    IF r.xa > r.fmax THEN
      kind := 'xid'; object := format('%I.%I', r.nspname, r.relname); rank_class := 3;
      current_value := r.xa; limit_value := r.fmax; used_fraction := NULL; until_date := NULL;
      state := 'no rate yet'; unknowns := '{}';
      detail := format('xid age %s, past this table''s autovacuum_freeze_max_age %s: an anti-wraparound vacuum is due, whatever autovacuum_enabled says', r.xa, r.fmax);
      "then" := ARRAY['a forced vacuum need not lower the age: it freezes only rows older than vacuum_freeze_min_age'];
      rank_label := lbl[rank_class]; RETURN NEXT;
    END IF;
  END LOOP;

  -- s6: member space is not readable without superuser, and 0.1 does not compute its limit even with it.
  kind := 'multixact'; object := 'member space'; rank_class := 5;
  current_value := NULL; limit_value := NULL; used_fraction := NULL; until_date := NULL;
  state := 'not established'; "then" := '{}';
  IF has_function_privilege('pg_ls_dir(text)', 'EXECUTE') THEN
    SELECT count(*) INTO nfiles FROM pg_ls_dir('pg_multixact/members');
    detail := format('%s member segment file(s); the member-space limit is not computed in 0.1', nfiles);
  ELSE
    detail := 'member space cannot be read by this role: listing pg_multixact/members needs superuser, or EXECUTE on pg_ls_dir(text)';
  END IF;
  unknowns := ARRAY[detail]; rank_label := lbl[rank_class]; RETURN NEXT;

  -- ---------------------------------------------------------------- time-range partitions
  -- s7, s11. A fixed boundary, no rate. Non-time keys are skipped. A DEFAULT partition is not a safety
  -- net: past the bound, rows go there silently, and then block creating the partition they belong in.
  FOR r IN
    SELECT p.partrelid, n.nspname, c.relname, a.atttypid,
           (SELECT max((regexp_match(pg_get_expr(pc.relpartbound, pc.oid), 'TO \(''([^'']+)''\)'))[1]::timestamptz)
              FROM pg_inherits i JOIN pg_class pc ON pc.oid = i.inhrelid WHERE i.inhparent = p.partrelid) AS last_bound,
           (SELECT pc.oid FROM pg_inherits i JOIN pg_class pc ON pc.oid = i.inhrelid
             WHERE i.inhparent = p.partrelid AND pg_get_expr(pc.relpartbound, pc.oid) = 'DEFAULT') AS default_oid,
           (SELECT bool_or(pg_get_expr(pc.relpartbound, pc.oid) LIKE '%TO (MAXVALUE)')
              FROM pg_inherits i JOIN pg_class pc ON pc.oid = i.inhrelid WHERE i.inhparent = p.partrelid) AS open_ended
      FROM pg_partitioned_table p JOIN pg_class c ON c.oid = p.partrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = p.partrelid AND a.attnum = p.partattrs[0]
     WHERE p.partstrat = 'r' AND p.partnatts = 1
       AND a.atttypid IN ('timestamptz'::regtype, 'timestamp'::regtype, 'date'::regtype)
  LOOP
    CONTINUE WHEN r.last_bound IS NULL OR r.open_ended;   -- a partition TO (MAXVALUE) has no boundary
    kind := 'partition'; object := format('%I.%I', r.nspname, r.relname);
    current_value := NULL; limit_value := NULL; used_fraction := NULL; until_date := r.last_bound;
    "then" := '{}'; unknowns := '{}';
    IF r.last_bound <= now() THEN
      rank_class := 1; state := 'reached';
      IF r.default_oid IS NULL THEN
        detail := format('the last partition ended at %s: inserts for the present fail now', r.last_bound);
      ELSE
        detail := format('the last partition ended at %s: rows for the present go silently into the DEFAULT', r.last_bound);
      END IF;
    ELSIF r.last_bound <= now() + date_window THEN
      rank_class := 2; state := 'date';
      detail := format('the last partition ends at %s', r.last_bound);
    ELSE
      CONTINUE;
    END IF;
    IF r.default_oid IS NOT NULL THEN
      IF has_table_privilege(r.default_oid, 'SELECT') AND has_schema_privilege(r.nspname, 'USAGE') THEN
        BEGIN
          EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s)', r.default_oid::regclass) INTO hasrows;
          IF hasrows THEN
            "then" := ARRAY[format('the DEFAULT %s holds rows past the last bound: the partition for their range cannot be created until they are moved', r.default_oid::regclass)];
          END IF;
        EXCEPTION WHEN lock_not_available THEN
          unknowns := ARRAY[format('whether the DEFAULT %s holds rows is not established: it is locked', r.default_oid::regclass)];
        END;
      ELSE
        unknowns := ARRAY[format('whether the DEFAULT %s holds rows is not established: this role cannot read it', r.default_oid::regclass)];
      END IF;
    END IF;
    rank_label := lbl[rank_class]; RETURN NEXT;
  END LOOP;

  -- ---------------------------------------------------------------- replication slots
  -- s8. With max_slot_wal_keep_size set, invalidation is the limit; unset, the disk is, which this
  -- tool cannot read.
  FOR r IN
    SELECT slot_name, slot_type, active, wal_status, safe_wal_size,
           pg_wal_lsn_diff(CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn() ELSE pg_current_wal_lsn() END, restart_lsn) AS retained
      FROM pg_replication_slots WHERE restart_lsn IS NOT NULL OR wal_status = 'lost'
  LOOP
    kind := 'replication slot'; object := r.slot_name; until_date := NULL; "then" := '{}'; unknowns := '{}';
    current_value := r.retained; limit_value := NULL; used_fraction := NULL;
    IF r.wal_status = 'lost' THEN
      rank_class := 1; state := 'invalidated';
      detail := format('slot %s has been invalidated: its consumer must be rebuilt', r.slot_name);
    ELSIF r.wal_status = 'unreserved' THEN
      rank_class := 1; state := 'about to be invalidated';
      detail := format('slot %s has passed max_slot_wal_keep_size: the next checkpoint invalidates it', r.slot_name);
    ELSIF r.safe_wal_size IS NOT NULL AND NOT r.active THEN
      rank_class := 3; state := 'no rate yet'; limit_value := r.safe_wal_size + r.retained;
      used_fraction := round(r.retained / nullif(r.safe_wal_size + r.retained, 0), 4);
      detail := format('inactive slot %s: %s bytes of WAL left before it is invalidated', r.slot_name, r.safe_wal_size);
      CONTINUE WHEN used_fraction < min_used;
    ELSIF r.safe_wal_size IS NULL AND NOT r.active THEN
      rank_class := 5; state := 'not established';
      detail := format('inactive slot %s retains %s bytes of WAL with max_slot_wal_keep_size unset: nothing invalidates it, and the limit is the disk holding pg_wal, which this tool cannot read', r.slot_name, r.retained);
      unknowns := ARRAY[detail];
    ELSE
      CONTINUE;
    END IF;
    rank_label := lbl[rank_class]; RETURN NEXT;
  END LOOP;

  -- ---------------------------------------------------------------- connections
  -- s10. A peak against a limit, not a rate; in 0.1 the current count, since there is no history.
  -- Per role and per database too. Superusers are exempt from both of those.
  -- Without pg_read_all_stats a role sees other sessions with their type, user and database hidden, so
  -- every count would read low, down to 0 of N: not established, rather than "fine". Measured on 14 and 18.
  IF NOT pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER') THEN
    kind := 'connections'; object := 'server, roles and databases'; rank_class := 5; state := 'not established';
    current_value := NULL; limit_value := NULL; used_fraction := NULL; until_date := NULL; "then" := '{}';
    detail := 'connection counts are not established: without pg_read_all_stats this role cannot see which sessions are client connections, or whose';
    unknowns := ARRAY[detail];
    rank_label := lbl[rank_class]; RETURN NEXT;
  ELSE
    reserved := nullif(current_setting('reserved_connections', true), '')::int;
    kind := 'connections'; object := 'server'; until_date := NULL; unknowns := '{}';
    current_value := (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend');
    limit_value := current_setting('max_connections')::int - current_setting('superuser_reserved_connections')::int - coalesce(reserved, 0);
    used_fraction := round(current_value / nullif(limit_value, 0), 4);
    "then" := CASE WHEN reserved IS NULL THEN ARRAY['reserved_connections does not exist before PostgreSQL 16: only superuser_reserved_connections is held back'] ELSE '{}' END;
    IF used_fraction >= min_used THEN
      rank_class := CASE WHEN current_value >= limit_value THEN 1 ELSE 4 END; rank_label := lbl[rank_class];
      state := CASE WHEN rank_class = 1 THEN 'full' ELSE 'current, not a peak' END;
      detail := format('%s of %s connections for ordinary roles in use', current_value, limit_value);
      rank_label := lbl[rank_class]; RETURN NEXT;
    END IF;
    FOR r IN
      SELECT 'role' AS k, rolname AS name, rolconnlimit AS lim, (SELECT count(*) FROM pg_stat_activity WHERE usename = rolname AND backend_type = 'client backend') AS used
        FROM pg_roles WHERE rolconnlimit >= 0 AND NOT rolsuper
      UNION ALL
      SELECT 'database', datname, datconnlimit, (SELECT count(*) FROM pg_stat_activity a WHERE a.datname = d.datname AND a.backend_type = 'client backend')
        FROM pg_database d WHERE datconnlimit >= 0
    LOOP
      CONTINUE WHEN r.lim = 0 OR r.used::numeric / r.lim < min_used;
      kind := 'connections'; object := format('%s %I', r.k, r.name); current_value := r.used; limit_value := r.lim;
      used_fraction := round(r.used::numeric / r.lim, 4); until_date := NULL; unknowns := '{}';
      rank_class := CASE WHEN r.used >= r.lim THEN 1 ELSE 4 END; rank_label := lbl[rank_class];
      state := CASE WHEN rank_class = 1 THEN 'full' ELSE 'current, not a peak' END;
      detail := format('%s of %s connections in use%s', r.used, r.lim, CASE WHEN rank_class = 1 THEN ': new sessions are refused' ELSE '' END);
      "then" := ARRAY['superusers are exempt from this limit'];
      rank_label := lbl[rank_class]; RETURN NEXT;
    END LOOP;
  END IF;

  -- ---------------------------------------------------------------- passwords
  -- s9. A fixed date, no rate. Expiry refuses password logins only.
  FOR r IN
    SELECT rolname, rolvaliduntil FROM pg_roles
     WHERE rolcanlogin AND rolvaliduntil IS NOT NULL AND rolvaliduntil <> 'infinity'
       AND rolvaliduntil <= now() + date_window
  LOOP
    kind := 'password'; object := format('role %I', r.rolname); current_value := NULL; limit_value := NULL;
    used_fraction := NULL; until_date := r.rolvaliduntil; unknowns := '{}';
    "then" := ARRAY['logins that do not use a password are not affected: trust, peer and certificate logins still work'];
    IF r.rolvaliduntil <= now() THEN
      rank_class := 1; state := 'expired'; detail := format('the password of %I has expired', r.rolname);
    ELSE
      rank_class := 2; state := 'date'; detail := format('the password of %I expires at %s', r.rolname, r.rolvaliduntil);
    END IF;
    rank_label := lbl[rank_class]; RETURN NEXT;
  END LOOP;
END
$fn$;

COMMENT ON FUNCTION @extschema@.limit_runway_findings(numeric, interval) IS
  'Every limit worth reporting, with its finding state (failing now, a date, no rate yet, a peak, not established), current value, limit, share used where meaningful, secondary facts in "then" and gaps in "unknowns". Never a negative count and never more than 100% used. 0.1 has no history, so no projected dates. Read-only.';

CREATE VIEW @extschema@.limit_runway AS
  SELECT * FROM @extschema@.limit_runway_findings()
   ORDER BY rank_class, until_date NULLS LAST, used_fraction DESC NULLS LAST, object;

COMMENT ON VIEW @extschema@.limit_runway IS
  'limit_runway_findings() with its defaults, most urgent first, as docs/ranking.md orders them.';

CREATE FUNCTION @extschema@.limit_runway_text(min_used numeric DEFAULT 0.5,
                                              date_window interval DEFAULT interval '30 days')
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  SELECT format('[%s] %s %s: %s.', f.rank_label, f.kind, f.object, f.detail)
         || coalesce((SELECT ' Then: ' || string_agg(t, '; ') || '.' FROM unnest(f."then") t), '')
         || coalesce((SELECT ' Not established: ' || string_agg(u, '; ') || '.'
                        FROM unnest(f.unknowns) u WHERE u <> f.detail), '')
    FROM @extschema@.limit_runway_findings(min_used, date_window) f
   ORDER BY f.rank_class, f.until_date NULLS LAST, f.used_fraction DESC NULLS LAST, f.object
$$;

-- Closed by default, invoker's rights, as pg_bloat_cause: a role reads what its own privileges allow,
-- and the unknowns say what that hides.
REVOKE EXECUTE ON FUNCTION @extschema@.limit_runway_findings(numeric, interval) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.limit_runway_text(numeric, interval) FROM PUBLIC;
