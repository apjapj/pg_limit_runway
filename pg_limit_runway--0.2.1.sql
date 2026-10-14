/* pg_limit_runway--0.2.1.sql
 *
 * What will break next: every hard limit in a PostgreSQL database, and the date each one is reached.
 * This is 0.2.1. It changes no SQL: every object is byte-identical to what 0.2 created, and the
 * only difference in this file is the header. 0.2.1 exists so the release matches the tag and the
 * README: it carries the corrected README banner and the ported doc-facts lint, neither of which
 * is SQL. See CHANGELOG-equivalent notes in git log for 0.2.1.
 *
 * The SQL surface is entirely 0.2's: limit_runway (view), limit_runway_findings(), limit_runway_text(),
 * limit_runway_sample(), limit_runway_prune(), the three helpers, and limit_runway_history. An
 * installation updated from 0.2 to 0.2.1 runs an empty update path, because there is nothing to change.
 *
 * See pg_limit_runway--0.2.sql for the full header, which describes what each object is and why.
 */
\echo Use "CREATE EXTENSION pg_limit_runway" to load this file. \quit

DO $floor$
BEGIN
  IF current_setting('server_version_num')::int < 140000 THEN
    RAISE EXCEPTION 'pg_limit_runway needs PostgreSQL 14 or later; this is %', current_setting('server_version');
  END IF;
END
$floor$;

-- ---------------------------------------------------------------- the history (0.2)
-- One narrow row per limit per sample (docs/history.md). position and limit_value are in the same unit
-- per kind: calls of nextval() for a sequence, a value for a foreign key, an age for xid and multixact,
-- bytes for a slot. epoch counts breaks in the series: the sampler starts a new one whenever the
-- position falls or the limit changes, and a rate is only ever fitted within one.
CREATE TABLE @extschema@.limit_runway_history (
  sampled_at   timestamptz NOT NULL,
  kind         text        NOT NULL,
  object       text        NOT NULL,
  position     numeric     NOT NULL,
  limit_value  numeric     NOT NULL,
  epoch        int         NOT NULL DEFAULT 0,
  PRIMARY KEY (kind, object, sampled_at)
);
-- Pruning reads by time across every key, which the primary key cannot serve.
CREATE INDEX limit_runway_history_sampled_at_idx ON @extschema@.limit_runway_history (sampled_at);

COMMENT ON TABLE @extschema@.limit_runway_history IS
  'Samples written by limit_runway_sample(), one row per limit per sample. Read through '
  'limit_runway_findings() and the view, which fit a rate within the newest epoch only.';

-- The samples are the user's data, not the extension's, so pg_dump keeps them.
SELECT pg_catalog.pg_extension_config_dump('@extschema@.limit_runway_history', '');

-- ---------------------------------------------------------------- every sequence, counted in calls
-- The one place a sequence's position is read and counted, so that limit_runway_findings() and
-- limit_runway_sample() cannot disagree about what "calls left" means. Counted in calls of nextval(),
-- from the value the next call hands out, in steps of the increment (rate.md, and a truth table of 32
-- shapes measured on 14 and 18). The position is read from the sequence itself, because pg_sequences
-- hides it until the first call and so misses setval(..., false). A sequence this role cannot read, or
-- that is locked past lock_timeout, comes back with readable or locked set and no figures, never with
-- a figure that looks like an answer.
CREATE FUNCTION @extschema@.limit_runway_sequences()
RETURNS TABLE (
  object      text,
  seq_schema  name,
  seq_name    name,
  inc         bigint,
  seqmax      bigint,
  seqmin      bigint,
  seqcycle    boolean,
  tbl_schema  name,
  tbl_name    name,
  tbl_oid     oid,
  attname     name,
  attnum      smallint,
  coltype     text,
  colmax      numeric,
  readable    boolean,
  locked      boolean,
  nv          numeric,
  cur         numeric,
  step        numeric,
  eff         numeric,
  nleft       numeric,
  total       numeric,
  wraps       boolean,
  frac        numeric,
  -- The column whose DEFAULT calls nextval() on this sequence, when no dependency ties the two
  -- together. Non-null only in that case, because a DEFAULT is not a link: see the detection
  -- join below, and docs/rate.md.
  dflt_object text,
  dflt_coltype text
)
LANGUAGE plpgsql STABLE
SET lock_timeout = '1s'
AS $fn$
#variable_conflict use_column
DECLARE
  q       record;
  colmin  numeric;
  lv      numeric;
  called  boolean;
BEGIN
  FOR q IN
    SELECT sn.nspname AS q_seq_schema, s.relname AS q_seq_name, sq.seqincrement AS q_inc,
           sq.seqmax AS q_seqmax, sq.seqmin AS q_seqmin, sq.seqcycle AS q_seqcycle,
           tn.nspname AS q_tbl_schema, t.relname AS q_tbl_name, t.oid AS q_tbl_oid,
           a.attname AS q_attname, a.attnum AS q_attnum, a.atttypid AS q_atttypid,
           format_type(a.atttypid, a.atttypmod) AS q_coltype,
           has_sequence_privilege(s.oid, 'SELECT') AS q_can_read,
           dl.d_object AS q_d_object, dl.d_coltype AS q_d_coltype
      FROM pg_class s
      JOIN pg_namespace sn  ON sn.oid = s.relnamespace
      JOIN pg_sequence sq   ON sq.seqrelid = s.oid
      LEFT JOIN pg_depend d ON d.objid = s.oid AND d.classid = 'pg_class'::regclass
                           AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
      LEFT JOIN pg_class t       ON t.oid = d.refobjid
      LEFT JOIN pg_namespace tn  ON tn.oid = t.relnamespace
      LEFT JOIN pg_attribute a   ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
     -- A column DEFAULT nextval() is NOT a dependency, so a sequence wired that way has no
     -- pg_depend row and its column is invisible above. This finds that column so the finding can
     -- say the limit is unknown, rather than print the sequence's own MAXVALUE as if it were the
     -- limit. It cannot raise on a default it does not recognise: the regclass is cast only after
     -- the pattern matched, inside a subquery, so anything else yields no row.
     LEFT JOIN LATERAL (
       SELECT format('%I.%I.%I', dn.nspname, dc.relname, da.attname) AS d_object,
              format_type(da.atttypid, NULL) AS d_coltype
         FROM pg_attrdef ad
         JOIN pg_class     dc ON dc.oid = ad.adrelid
         JOIN pg_namespace dn ON dn.oid = dc.relnamespace
         JOIN pg_attribute da ON da.attrelid = ad.adrelid AND da.attnum = ad.adnum
        WHERE da.atttypid IN ('int2'::regtype, 'int4'::regtype, 'int8'::regtype)
          AND (SELECT (regexp_match(pg_get_expr(ad.adbin, ad.adrelid),
                                    '^nextval\(''(.+?)''::regclass\)$'))[1]) IS NOT NULL
          AND (SELECT (regexp_match(pg_get_expr(ad.adbin, ad.adrelid),
                                    '^nextval\(''(.+?)''::regclass\)$'))[1])::regclass = s.oid
        ORDER BY dn.nspname, dc.relname, da.attnum
        LIMIT 1
     ) dl ON true
     WHERE s.relkind = 'S' AND sn.nspname NOT IN ('pg_catalog', 'information_schema')
       AND NOT pg_is_other_temp_schema(sn.oid)
     ORDER BY sn.nspname, s.relname   -- so the names listed in a not-established row are the same each call
  LOOP
    seq_schema := q.q_seq_schema; seq_name := q.q_seq_name; inc := q.q_inc; seqmax := q.q_seqmax;
    seqmin := q.q_seqmin; seqcycle := q.q_seqcycle; tbl_schema := q.q_tbl_schema; tbl_name := q.q_tbl_name;
    tbl_oid := q.q_tbl_oid; attname := q.q_attname; attnum := q.q_attnum; coltype := q.q_coltype;
    -- Only meaningful when there is no dependency: if a column owns the sequence, the dependency
    -- is the answer and a default pointing elsewhere would be noise.
    dflt_object  := CASE WHEN q.q_attname IS NULL THEN q.q_d_object  END;
    dflt_coltype := CASE WHEN q.q_attname IS NULL THEN q.q_d_coltype END;
    colmax := CASE q.q_atttypid WHEN 'int2'::regtype THEN 32767 WHEN 'int4'::regtype THEN 2147483647
                                WHEN 'int8'::regtype THEN 9223372036854775807 END;
    colmin := CASE q.q_atttypid WHEN 'int2'::regtype THEN -32768 WHEN 'int4'::regtype THEN -2147483648
                                WHEN 'int8'::regtype THEN -9223372036854775808 END;
    -- A sequence no column owns (s3_desc) is reported under its own name, against its own limits.
    object := CASE WHEN q.q_attname IS NULL THEN format('%I.%I', q.q_seq_schema, q.q_seq_name)
                   ELSE format('%I.%I.%I', q.q_tbl_schema, q.q_tbl_name, q.q_attname) END;
    readable := q.q_can_read; locked := false;
    nv := NULL; cur := NULL; step := NULL; eff := NULL; nleft := NULL; total := NULL; wraps := NULL; frac := NULL;
    IF readable THEN
      BEGIN
        EXECUTE format('SELECT last_value, is_called FROM %I.%I', q.q_seq_schema, q.q_seq_name) INTO lv, called;
      EXCEPTION WHEN lock_not_available THEN
        locked := true;
      END;
    END IF;
    IF readable AND NOT locked THEN
      nv := CASE WHEN called THEN lv + inc ELSE lv END;
      cur := nv - inc;
      step := abs(inc);
      IF inc > 0 THEN
        eff := least(seqmax, coalesce(colmax, seqmax));
        nleft := CASE WHEN nv > eff THEN 0 ELSE floor((eff - nv) / step) + 1 END;
        total := floor((eff - seqmin) / step) + 1;
        wraps := seqcycle AND eff = seqmax;   -- a column narrower than the sequence fails before the wrap
      ELSE
        eff := greatest(seqmin, coalesce(colmin, seqmin));
        nleft := CASE WHEN nv < eff THEN 0 ELSE floor((nv - eff) / step) + 1 END;
        total := floor((seqmax - eff) / step) + 1;
        wraps := seqcycle AND eff = seqmin;
      END IF;
      frac := 1 - least(nleft, total) / total;
    END IF;
    RETURN NEXT;
  END LOOP;
END
$fn$;

COMMENT ON FUNCTION @extschema@.limit_runway_sequences() IS
  'Every sequence this database holds, with its position counted in calls of nextval(): the next '
  'value, calls left and calls in its whole range, against the tighter of its own limits and its '
  'column''s. Shared by limit_runway_findings() and limit_runway_sample(). A sequence the caller '
  'cannot read, or that is locked, has readable or locked set and no figures.';

-- ---------------------------------------------------------------- the rate, from the newest epoch
-- rate.md's rules, as one query per series: only the newest epoch; the slope over the last 7 days of it
-- beside the slope over the last 24 hours; the date from the NEWEST sample's position and limit. A
-- series with one sample has no rate, and one whose position has not moved has a rate of zero, which
-- the caller reports as "not moving", not as a date.
CREATE FUNCTION @extschema@.limit_runway_projection(p_kind text, p_object text)
RETURNS TABLE (
  samples          bigint,
  epoch            int,
  segment_start    timestamptz,
  newest_at        timestamptz,
  newest_position  numeric,
  newest_limit     numeric,
  rate_7d          numeric,
  rate_24h         numeric,
  until_7d         timestamptz,
  until_24h        timestamptz,
  average_gap      interval
)
LANGUAGE sql STABLE
AS $$
  WITH k AS (
    SELECT max(h.epoch) AS e FROM @extschema@.limit_runway_history h
     WHERE h.kind = p_kind AND h.object = p_object
  ), seg AS (
    SELECT h.sampled_at, h.position, h.limit_value FROM @extschema@.limit_runway_history h, k
     WHERE h.kind = p_kind AND h.object = p_object AND h.epoch = k.e
  ), n AS (
    SELECT * FROM seg ORDER BY sampled_at DESC LIMIT 1
  ), s AS (
    SELECT count(*) AS c, min(sampled_at) AS mn, max(sampled_at) AS mx FROM seg
  ), w7 AS (
    -- The window reaches 10% past its nominal length, so the sample that marks its start still counts
    -- when a scheduler's hourly tick lands a little after it: a series sampled hourly for 7 days has
    -- its 7-day point, rather than losing it to a second and falling back to a later one.
    SELECT seg.* FROM seg, n WHERE seg.sampled_at >= n.sampled_at - interval '7 days' * 1.1
                               AND seg.sampled_at < n.sampled_at
     ORDER BY seg.sampled_at LIMIT 1
  ), w24 AS (
    SELECT seg.* FROM seg, n WHERE seg.sampled_at >= n.sampled_at - interval '24 hours' * 1.1
                               AND seg.sampled_at < n.sampled_at
     ORDER BY seg.sampled_at LIMIT 1
  ), r AS (
    SELECT n.sampled_at AS at, n.position AS pos, n.limit_value AS lim,
           (n.position - w7.position)
             / nullif(extract(epoch FROM n.sampled_at - w7.sampled_at) / 86400, 0)   AS r7,
           (n.position - w24.position)
             / nullif(extract(epoch FROM n.sampled_at - w24.sampled_at) / 86400, 0)  AS r24
      FROM n LEFT JOIN w7 ON true LEFT JOIN w24 ON true
  )
  SELECT s.c, k.e, s.mn, r.at, r.pos, r.lim, r.r7, r.r24,
         CASE WHEN r.r7  > 0 THEN r.at + (greatest(r.lim - r.pos, 0) / r.r7)  * interval '1 day' END,
         CASE WHEN r.r24 > 0 THEN r.at + (greatest(r.lim - r.pos, 0) / r.r24) * interval '1 day' END,
         CASE WHEN s.c > 1 THEN (s.mx - s.mn) / (s.c - 1) END
    FROM r, s, k
$$;

COMMENT ON FUNCTION @extschema@.limit_runway_projection(text, text) IS
  'The rate of one series from limit_runway_history, within its newest epoch only: samples, the 7-day '
  'and 24-hour slopes per day, and the dates each gives from the newest sample. No rows when the '
  'series has never been sampled.';

-- The projection as a finding: the state, the date that ranks it, and the words appended to the detail.
-- One definition, used for every kind the sampler records, so a sequence and an xid age are projected
-- and worded by the same rules.
CREATE FUNCTION @extschema@.limit_runway_project(p_kind text, p_object text, p_verb text)
RETURNS TABLE (state text, until_date timestamptz, suffix text)
LANGUAGE sql STABLE
AS $$
  WITH p AS (SELECT * FROM @extschema@.limit_runway_projection(p_kind, p_object)),
  f AS (
    SELECT p.*,
           -- rate.md: two slopes more than a factor of two apart are both given, not one chosen.
           (p.rate_24h IS NOT NULL AND p.rate_7d > 0
            AND (p.rate_24h > 2 * p.rate_7d OR 2 * p.rate_24h < p.rate_7d)) AS disagree,
           rtrim(rtrim(round(p.rate_7d, 2)::text, '0'), '.')  AS r7t,
           rtrim(rtrim(round(p.rate_24h, 2)::text, '0'), '.') AS r24t,
           rtrim(rtrim(round((extract(epoch FROM p.newest_at - p.segment_start) / 86400)::numeric, 1)::text, '0'), '.')
             || CASE WHEN round((extract(epoch FROM p.newest_at - p.segment_start) / 86400)::numeric, 1) = 1
                     THEN ' day' ELSE ' days' END AS span
      FROM p
  )
  SELECT CASE WHEN f.samples < 2 THEN 'no rate yet'
              WHEN coalesce(f.rate_7d, 0) <= 0 THEN 'not moving'
              ELSE 'projected' END,
         CASE WHEN f.samples >= 2 AND f.rate_7d > 0
              THEN CASE WHEN f.disagree THEN least(f.until_7d, f.until_24h) ELSE f.until_7d END END,
         CASE WHEN f.samples < 2
              THEN '; one sample so far, and a rate needs two'
              WHEN coalesce(f.rate_7d, 0) <= 0
              THEN format('; not moving: %s samples over %s show no change', f.samples, f.span)
              ELSE format('; at %s per day, from %s samples over %s, it %s about %s',
                          f.r7t, f.samples, f.span, p_verb, to_char(f.until_7d, 'YYYY-MM-DD HH24:MI'))
                   || CASE WHEN f.disagree
                           THEN format('; the last 24 hours ran at %s per day, which gives %s',
                                       f.r24t, to_char(f.until_24h, 'YYYY-MM-DD HH24:MI'))
                           ELSE '' END
         END
         || CASE WHEN f.epoch > 0
                 THEN format('; the rate is from samples since %s, when the series restarted',
                             to_char(f.segment_start, 'YYYY-MM-DD HH24:MI'))
                 ELSE '' END
         || CASE WHEN f.samples > 1 AND now() - f.newest_at > greatest(3 * f.average_gap, interval '1 hour')
                 THEN format('; the newest sample is %s old', date_trunc('minute', now() - f.newest_at))
                 ELSE '' END
    FROM f
$$;

COMMENT ON FUNCTION @extschema@.limit_runway_project(text, text, text) IS
  'One series'' projection as a finding: no rate yet, not moving, or projected with the date that ranks '
  'it, and the words to append to its detail. Both dates when the 7-day and 24-hour rates disagree by '
  'more than a factor of two, ranked by the sooner.';

-- The order (docs/ranking.md): 1 failing now, 2 a date, 3 no rate yet or not moving (by share used),
-- 4 peaks, 5 not established. Class 2 holds fixed dates (a password's expiry, a partition's last bound)
-- and, since 0.2, projected ones, on one timeline.
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
  eff        numeric;
  cur        numeric;
  data_at    numeric;
  frac       numeric;
  nv         numeric;
  step       numeric;
  nleft      numeric;
  total      numeric;
  wraps      boolean;
  taken      boolean;
  th         text[];
  un         text[];
  lbl        text[] := ARRAY['failing now', 'date', 'no rate yet', 'peak', 'not established'];
  reserved   int;
  nfiles     bigint;
  hasrows    boolean;
  unread     text[] := '{}';
  noseq      text[] := '{}';
  -- 0.2: rates, where the caller can read the samples. Without SELECT on the history every rate is
  -- unknown, and one row says so rather than every row quietly saying "no rate yet".
  can_hist   boolean := has_table_privilege('@extschema@.limit_runway_history', 'SELECT');
  sample_thr numeric := coalesce(nullif(current_setting('limit_runway.sample_min_used', true), '')::numeric, 0.10);
  pj         record;
BEGIN
  -- ---------------------------------------------------------------- sequences tied to a column
  -- s1 to s3, s11, s12. The limit is the tighter of the sequence's own and the COLUMN's type, found
  -- through pg_depend (s1: a bigint sequence on an int4 column). A failed insert still consumes a value
  -- (s1), so a sequence can stand past the column's maximum: that is "exhausted", never a negative count.
  -- A sequence behind its data (s12) collides on the next default id: a state with a fix to run by hand,
  -- detected only through an index whose leading column is the column, never a scan.
  FOR r IN SELECT * FROM @extschema@.limit_runway_sequences()
  LOOP
    th := '{}'; un := '{}';
    kind := 'sequence';
    object := r.object;
    colmax := r.colmax;
    IF NOT r.readable THEN
      noseq := noseq || format('%I.%I', r.seq_schema, r.seq_name);   -- reported once below
      CONTINUE;
    END IF;
    IF r.locked THEN
      noseq := noseq || format('%I.%I (locked)', r.seq_schema, r.seq_name);
      CONTINUE;
    END IF;
    -- Counted in calls of nextval() by limit_runway_sequences(), the one place that arithmetic lives,
    -- so the sampler and this function cannot disagree about what "calls left" means.
    nv := r.nv; cur := r.cur; step := r.step; eff := r.eff; nleft := r.nleft; total := r.total;
    wraps := r.wraps; frac := r.frac;
    IF eff < coalesce(colmax, eff) AND r.inc > 0 AND NOT r.seqcycle THEN
      th := th || format('the limit is the sequence''s MAXVALUE %s, not the column''s %s', eff, r.coltype);
    END IF;

    -- The data: only through an index whose leading column is this one (s12, s13), at the end the
    -- sequence is heading for: the highest key for an ascending sequence, the lowest for a descending one.
    data_at := NULL; taken := NULL;
    IF r.attname IS NOT NULL THEN
      IF EXISTS (SELECT 1 FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
                   JOIN pg_am am ON am.oid = ic.relam
                  WHERE i.indrelid = r.tbl_oid AND i.indkey[0] = r.attnum AND am.amname = 'btree'
                    AND i.indpred IS NULL AND i.indisvalid) THEN
        IF has_table_privilege(r.tbl_oid, 'SELECT') AND has_schema_privilege(r.tbl_schema, 'USAGE') THEN
          -- The index's end entry: ORDER BY ... LIMIT 1 reads one leaf page, however large the table, and
          -- whether the next value is already taken is one more index lookup.
          BEGIN
            EXECUTE format('SELECT %I::numeric FROM %I.%I WHERE %I IS NOT NULL ORDER BY %I %s LIMIT 1',
                           r.attname, r.tbl_schema, r.tbl_name, r.attname, r.attname,
                           CASE WHEN r.inc > 0 THEN 'DESC' ELSE 'ASC' END) INTO data_at;
            EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I WHERE %I = $1)', r.tbl_schema, r.tbl_name, r.attname)
               INTO taken USING nv;
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

    -- A column DEFAULT nextval() is not a dependency, so a sequence wired that way has no column for
    -- this extension to read, and eff below is the sequence's own MAXVALUE rather than the column's.
    -- Said as an unknown rather than left as a number that reads like an answer, because the column's
    -- limit is the real one and it is lower: an int4 column next to a bigint sequence runs out at
    -- 2147483647, and the sequence's own ceiling is far above that. Found by testing the shape, after
    -- documenting the standalone case and nearly concluding there was no gap (docs/rate.md).
    IF r.dflt_object IS NOT NULL AND r.coltype IS NULL THEN
      un := un || format('the limit shown is the sequence''s own MAXVALUE, not %s''s: that column calls nextval() on this sequence by DEFAULT, and a DEFAULT is not a dependency, so the column limit cannot be read. ALTER SEQUENCE %I.%I OWNED BY %s; makes it visible',
                         r.dflt_coltype, r.seq_schema, r.seq_name, r.dflt_object);
    END IF;

    current_value := cur; limit_value := eff; until_date := NULL; "then" := th; unknowns := un;
    -- The four states, each on its own test: behind the data, exhausted, a count, nothing to report.
    IF data_at IS NOT NULL AND ((r.inc > 0 AND data_at >= nv) OR (r.inc < 0 AND data_at <= nv)) THEN
      -- Keys already exist where the sequence is heading. For a cycling sequence that is the wrap.
      rank_class := 1; used_fraction := NULL;
      state := CASE WHEN r.seqcycle THEN 'cycled into existing keys' ELSE 'behind the data' END;
      -- setval past the data is the fix only for a sequence that does not cycle: a cycling one set to the
      -- end of its data wraps straight back into it (s3_cyc, s13_ring).
      detail := format('%s (sequence at %s, data at %s): %s. %s',
                       CASE WHEN r.seqcycle THEN 'the sequence has wrapped into existing keys' ELSE 'the sequence is behind the data' END,
                       cur, data_at,
                       CASE WHEN taken THEN format('the next default id, %s, is already taken, so the next insert fails', nv)
                            ELSE format('default ids from %s to %s collide with any rows that hold them', nv, data_at) END,
                       CASE WHEN r.seqcycle
                            THEN 'No setval fixes a cycling sequence: it would wrap back into the same keys. Free the old keys, or widen its range'
                            ELSE format('Fix, to run by hand: SELECT setval(%L, %s)', format('%I.%I', r.seq_schema, r.seq_name), data_at) END);
      rank_label := lbl[rank_class]; RETURN NEXT;
    ELSIF nleft = 0 AND NOT wraps THEN
      -- No call left: the next nextval() fails, or hands out a value the column cannot hold (s1).
      rank_class := 1; used_fraction := NULL; state := 'exhausted';
      detail := format('%s (%s) is exhausted: the limit is %s%s', object, coalesce(r.coltype, 'sequence'), eff,
                       CASE
                         -- Past the limit, which only burned values can do: nextval consumed them, so the
                         -- position is beyond eff and there is nothing left to hand out.
                         WHEN (r.inc > 0 AND cur > eff) OR (r.inc < 0 AND cur < eff)
                           THEN format(', and the sequence stands past it at %s: failed inserts still consume values', cur)
                         -- At the limit, and the limit IS the sequence's own ceiling, so there is no next
                         -- value at all: nextval() raises "reached maximum value" rather than returning one.
                         -- Saying "the next value would be %s" names a number the server has already
                         -- refused to produce, and an operator watching a pager sees the message and then
                         -- sees the error, which is two pieces of software disagreeing (s14).
                         WHEN eff = CASE WHEN r.inc > 0 THEN r.seqmax ELSE r.seqmin END
                           THEN CASE WHEN r.inc > 0
                                     THEN format(', and the next call fails: %s is the sequence''s MAXVALUE', eff)
                                     ELSE format(', and the next call fails: %s is the sequence''s MINVALUE', eff) END
                         -- At a limit narrower than the sequence, set by the column: the sequence does still
                         -- have a next value, and it is the column that will reject it.
                         ELSE format(', and the next value %s is past what %s can hold', nv, coalesce(r.coltype, 'the column'))
                       END);
      rank_label := lbl[rank_class]; RETURN NEXT;
    ELSIF frac >= min_used
          OR (can_hist AND frac >= sample_thr
              AND EXISTS (SELECT 1 FROM @extschema@.limit_runway_project('sequence', object,
                                          CASE WHEN wraps THEN 'wraps' ELSE 'runs out' END) p
                           WHERE p.until_date <= now() + date_window)) THEN
      rank_class := 3; used_fraction := round(frac, 4); state := 'no rate yet';
      -- nleft and total are counts of calls, never negative, and nleft <= total, so frac is in 0..1.
      detail := format('%s of %s values left%s (%s, %s%s)', nleft, total,
                       CASE WHEN wraps THEN format(' before it wraps to %s', CASE WHEN r.inc > 0 THEN r.seqmin ELSE r.seqmax END) ELSE '' END,
                       coalesce(r.coltype, 'sequence'), CASE WHEN r.inc > 0 THEN 'ascending' ELSE 'descending' END,
                       CASE WHEN step <> 1 THEN format(' by %s', step) ELSE '' END);
      IF wraps THEN
        "then" := "then" || 'it cycles instead of failing: after the wrap, inserts collide with any keys still held from the last pass'::text;
      END IF;
      IF can_hist THEN
        SELECT * INTO pj FROM @extschema@.limit_runway_project('sequence', object,
                                CASE WHEN wraps THEN 'wraps' ELSE 'runs out' END);
        IF FOUND THEN
          state := pj.state; until_date := pj.until_date; detail := detail || pj.suffix;
          IF pj.until_date IS NOT NULL THEN
            rank_class := 2;
            "then" := "then" || 'the rate counts calls of nextval(), failed inserts included, so the real date can come sooner: an error band this tool cannot narrow'::text;
          END IF;
        END IF;
      END IF;
      rank_label := lbl[rank_class]; RETURN NEXT;
    ELSIF r.attname IS NOT NULL AND NOT has_table_privilege(r.tbl_oid, 'SELECT') THEN
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
           format_type(pa.atttypid, pa.atttypmod) AS par_coltype, ps.last_value,
           has_sequence_privilege(s.oid, 'SELECT') AS can_read_seq, s.relname AS seq_name,
           (SELECT nspname FROM pg_namespace WHERE oid = s.relnamespace) AS seq_schema
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
    -- 0.2: a parent sequence this role cannot read was a position of 0 here, which is "fine". It is
    -- not established, and is listed with the other sequences the role cannot read.
    IF NOT r.can_read_seq THEN
      noseq := noseq || format('%I.%I', r.seq_schema, r.seq_name);
      CONTINUE;
    END IF;
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
      IF can_hist THEN
        SELECT * INTO pj FROM @extschema@.limit_runway_project('foreign key', object, 'runs out');
        IF FOUND THEN
          state := pj.state; until_date := pj.until_date; detail := detail || pj.suffix;
          IF pj.until_date IS NOT NULL THEN rank_class := 2; END IF;
        END IF;
      END IF;
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
      IF can_hist THEN
        SELECT * INTO pj FROM @extschema@.limit_runway_project('xid', object, 'reaches wraparound');
        IF FOUND THEN
          state := pj.state; until_date := pj.until_date; detail := detail || pj.suffix;
          IF pj.until_date IS NOT NULL THEN rank_class := 2; END IF;
        END IF;
      END IF;
      rank_label := lbl[rank_class]; RETURN NEXT;
    END IF;
    IF r.ma >= current_setting('autovacuum_multixact_freeze_max_age')::numeric THEN
      kind := 'multixact'; object := format('database %I', r.datname); rank_class := 3;
      current_value := r.ma; limit_value := 2147483648; used_fraction := round(r.ma / 2147483648, 4);
      until_date := NULL; state := 'no rate yet'; unknowns := '{}'; "then" := '{}';
      detail := format('multixact age %s: past autovacuum_multixact_freeze_max_age %s', r.ma, current_setting('autovacuum_multixact_freeze_max_age'));
      IF can_hist THEN
        SELECT * INTO pj FROM @extschema@.limit_runway_project('multixact', object, 'reaches wraparound');
        IF FOUND THEN
          state := pj.state; until_date := pj.until_date; detail := detail || pj.suffix;
          IF pj.until_date IS NOT NULL THEN rank_class := 2; END IF;
        END IF;
      END IF;
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

  -- 0.2: rates need the samples. A reader without SELECT on them gets 0.1's findings and this one gap.
  IF NOT can_hist THEN
    kind := 'history'; object := 'limit_runway_history'; rank_class := 5;
    current_value := NULL; limit_value := NULL; used_fraction := NULL; until_date := NULL;
    state := 'not established'; "then" := '{}';
    detail := 'rates and projected dates are not established: this role cannot read limit_runway_history';
    unknowns := ARRAY[detail];
    rank_label := lbl[rank_class]; RETURN NEXT;
  END IF;

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
      IF can_hist THEN
        SELECT * INTO pj FROM @extschema@.limit_runway_project('replication slot', object, 'is invalidated');
        IF FOUND THEN
          state := pj.state; until_date := pj.until_date; detail := detail || pj.suffix;
          IF pj.until_date IS NOT NULL THEN rank_class := 2; END IF;
        END IF;
      END IF;
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
  'Every limit worth reporting, with its finding state (failing now, a date, no rate yet or not moving, a peak, not established), current value, limit, share used where meaningful, secondary facts in "then" and gaps in "unknowns". Never a negative count and never more than 100% used. Since 0.2, a projected date where limit_runway_history holds two samples in one unbroken series that moved. Read-only.';

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

-- ---------------------------------------------------------------- the sampler (0.2)
-- docs/history.md. Runs with the caller's rights, like everything here (Piotr, 2026-10-11): what it
-- cannot read it does not record, and says so in what it returns, so a series is never pulled down by a
-- role that saw less. It consumes nothing it measures: no pg_current_xact_id(), and the one xid the
-- INSERT takes is the only one per sample (s5). sampled_at is a parameter so fixtures can lay down a
-- series at chosen instants with real consumption between them; scheduled, it is left NULL.
CREATE FUNCTION @extschema@.limit_runway_sample(sampled_at timestamptz DEFAULT NULL)
RETURNS TABLE (kind text, sampled bigint, below_threshold bigint, not_established bigint)
LANGUAGE plpgsql
SET lock_timeout = '1s'
AS $fn$
#variable_conflict use_column
DECLARE
  at      timestamptz := coalesce(limit_runway_sample.sampled_at, statement_timestamp());
  thr     numeric := coalesce(nullif(current_setting('limit_runway.sample_min_used', true), '')::numeric, 0.10);
  r       record;
  ks      text[]    := '{}';
  os      text[]    := '{}';
  ps      numeric[] := '{}';
  ls      numeric[] := '{}';
  n_seq   bigint := 0; b_seq bigint := 0; x_seq bigint := 0;
  n_fk    bigint := 0; b_fk  bigint := 0; x_fk  bigint := 0;
  n_db    bigint := 0;
  n_slot  bigint := 0;
  pos     numeric;
  lim     numeric;
BEGIN
  IF NOT has_table_privilege('@extschema@.limit_runway_history', 'INSERT')
     OR NOT has_table_privilege('@extschema@.limit_runway_history', 'SELECT') THEN
    RAISE EXCEPTION USING ERRCODE = 'insufficient_privilege',
      MESSAGE = 'limit_runway_sample() needs SELECT and INSERT on limit_runway_history; nothing was sampled',
      HINT = 'GRANT SELECT, INSERT ON limit_runway_history TO the role that runs the sample (INSTALL.md).';
  END IF;

  -- Sequences: from the threshold, or always once the key is in the table (answer 4).
  FOR r IN SELECT * FROM @extschema@.limit_runway_sequences() LOOP
    IF NOT r.readable OR r.locked THEN x_seq := x_seq + 1; CONTINUE; END IF;
    pos := r.total - least(r.nleft, r.total); lim := r.total;
    IF pos / lim >= thr
       OR EXISTS (SELECT 1 FROM @extschema@.limit_runway_history h
                   WHERE h.kind = 'sequence' AND h.object = r.object) THEN
      ks := ks || 'sequence'::text; os := os || r.object; ps := ps || pos; ls := ls || lim;
      n_seq := n_seq + 1;
    ELSE
      b_seq := b_seq + 1;
    END IF;
  END LOOP;

  -- Foreign keys narrower than the parent (s4): the parent's value against the child column's maximum.
  -- A parent sequence this role cannot read is not established, never a position of 0.
  FOR r IN
    SELECT cn.nspname AS child_schema, c.relname AS child_tbl, ca.attname AS child_col,
           ca.atttypid AS child_type, s.oid AS seq_oid, ps.last_value
      FROM pg_constraint con
      JOIN pg_class c ON c.oid = con.conrelid JOIN pg_namespace cn ON cn.oid = c.relnamespace
      JOIN pg_class p ON p.oid = con.confrelid
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
    IF NOT has_sequence_privilege(r.seq_oid, 'SELECT') THEN x_fk := x_fk + 1; CONTINUE; END IF;
    lim := CASE r.child_type WHEN 'int2'::regtype THEN 32767 ELSE 2147483647 END;
    pos := coalesce(r.last_value, 0);
    IF pos / lim >= thr
       OR EXISTS (SELECT 1 FROM @extschema@.limit_runway_history h
                   WHERE h.kind = 'foreign key'
                     AND h.object = format('%I.%I.%I', r.child_schema, r.child_tbl, r.child_col)) THEN
      ks := ks || 'foreign key'::text; os := os || format('%I.%I.%I', r.child_schema, r.child_tbl, r.child_col);
      ps := ps || pos; ls := ls || lim; n_fk := n_fk + 1;
    ELSE
      b_fk := b_fk + 1;
    END IF;
  END LOOP;

  -- XID and MultiXact age, per database, always: a handful of rows, and the rate is wanted long before
  -- the age reaches a threshold.
  FOR r IN SELECT datname, age(datfrozenxid)::numeric AS xa, mxid_age(datminmxid)::numeric AS ma
             FROM pg_database WHERE datallowconn LOOP
    ks := ks || ARRAY['xid', 'multixact']; os := os || ARRAY[format('database %I', r.datname), format('database %I', r.datname)];
    ps := ps || ARRAY[r.xa, r.ma]; ls := ls || ARRAY[2147483648::numeric, 2147483648::numeric];
    n_db := n_db + 1;
  END LOOP;

  -- Slots with max_slot_wal_keep_size set: retained WAL against retained plus what is left. Unset, the
  -- limit is the disk, which this tool cannot read, so there is nothing to project to.
  FOR r IN SELECT slot_name, safe_wal_size,
                  pg_wal_lsn_diff(CASE WHEN pg_is_in_recovery() THEN pg_last_wal_replay_lsn()
                                       ELSE pg_current_wal_lsn() END, restart_lsn) AS retained
             FROM pg_replication_slots
            WHERE restart_lsn IS NOT NULL AND safe_wal_size IS NOT NULL LOOP
    ks := ks || 'replication slot'::text; os := os || r.slot_name::text;
    ps := ps || r.retained; ls := ls || (r.retained + r.safe_wal_size);
    n_slot := n_slot + 1;
  END LOOP;

  -- One INSERT for the whole sample. A new epoch whenever the position fell or the limit changed since
  -- the previous sample of the same key: a setval or restore, a cycling sequence's wrap, a column
  -- widened, an age that fell after a freeze. A rate is never fitted across one.
  INSERT INTO @extschema@.limit_runway_history AS h (sampled_at, kind, object, position, limit_value, epoch)
  SELECT at, c.k, c.o, c.p, c.l,
         CASE WHEN prev.epoch IS NULL THEN 0
              WHEN c.p < prev.position OR c.l <> prev.limit_value THEN prev.epoch + 1
              ELSE prev.epoch END
    FROM unnest(ks, os, ps, ls) AS c(k, o, p, l)
    LEFT JOIN LATERAL (
      SELECT x.position, x.limit_value, x.epoch FROM @extschema@.limit_runway_history x
       WHERE x.kind = c.k AND x.object = c.o AND x.sampled_at < at
       ORDER BY x.sampled_at DESC LIMIT 1
    ) prev ON true
  ON CONFLICT DO NOTHING;

  RETURN QUERY VALUES ('sequence'::text, n_seq, b_seq, x_seq),
                      ('foreign key', n_fk, b_fk, x_fk),
                      ('xid', n_db, 0::bigint, 0::bigint),
                      ('multixact', n_db, 0::bigint, 0::bigint),
                      ('replication slot', n_slot, 0::bigint, 0::bigint);
END
$fn$;

COMMENT ON FUNCTION @extschema@.limit_runway_sample(timestamptz) IS
  'Append one sample of every limit with a rate to limit_runway_history: sequences and narrow foreign '
  'keys from limit_runway.sample_min_used (default 10%) used or once already sampled, xid and multixact '
  'age per database, and slots with max_slot_wal_keep_size set. Runs with the caller''s rights and '
  'returns, per kind, what it sampled, what was below the threshold, and what it could not read. '
  'Schedule hourly; sampled_at is for fixtures.';

-- One statement, not batches: a function cannot commit between batches, so batching inside one buys
-- nothing (docs/history.md). The sampled_at index bounds it.
CREATE FUNCTION @extschema@.limit_runway_prune(older_than interval DEFAULT interval '35 days')
RETURNS bigint
LANGUAGE sql
AS $$
  WITH d AS (
    DELETE FROM @extschema@.limit_runway_history
     WHERE sampled_at < statement_timestamp() - older_than
    RETURNING 1
  )
  SELECT count(*) FROM d
$$;

COMMENT ON FUNCTION @extschema@.limit_runway_prune(interval) IS
  'Delete samples older than older_than, default 35 days: a week for the slope and a month of history to '
  'explain a date. Returns how many rows went.';

-- The writer and the pruner are closed like the readers. The three helpers keep the default EXECUTE:
-- limit_runway_findings() calls them with its caller's rights, so a monitoring role granted the readers
-- must be able to call them, and they show nothing the caller's own privileges do not already allow
-- (an unreadable sequence comes back with no figures; the history is behind its own SELECT grant).
REVOKE EXECUTE ON FUNCTION @extschema@.limit_runway_sample(timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.limit_runway_prune(interval) FROM PUBLIC;
