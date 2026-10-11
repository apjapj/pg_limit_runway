-- test/02_history.sql: the sampler, the series and the projected date (0.2, docs/history.md).
--
-- Every sample here is laid down with an explicit sampled_at relative to now(), and the whole file runs
-- in one transaction, so now() is one instant throughout and every expected date is exact arithmetic
-- on that instant. The sequences are moved with setval between samples: that is the position the
-- sampler reads, and it is what a rate is fitted to. Each expectation is counted by hand from the
-- fixture, not computed by the expression under test.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pg_limit_runway;
\o
SELECT plan(33);

-- ---------------------------------------------------------------- the objects
SELECT has_table('limit_runway_history', 'the history table exists');
SELECT col_is_pk('limit_runway_history', ARRAY['kind', 'object', 'sampled_at'],
                 'one row per limit per sample: (kind, object, sampled_at)');
SELECT has_function('limit_runway_sample', ARRAY['timestamp with time zone'], 'limit_runway_sample(sampled_at) exists');
SELECT has_function('limit_runway_prune', ARRAY['interval'], 'limit_runway_prune(older_than) exists');
SELECT ok((SELECT 'limit_runway_history'::regclass = ANY (extconfig) FROM pg_extension
            WHERE extname = 'pg_limit_runway'),
          'the samples are registered with pg_dump: they are the user''s data, not the extension''s');
SELECT ok(NOT has_function_privilege('public', 'limit_runway_sample(timestamptz)', 'EXECUTE')
          AND NOT has_function_privilege('public', 'limit_runway_prune(interval)', 'EXECUTE'),
          'the writer and the pruner are not executable by PUBLIC');

-- ---------------------------------------------------------------- fixtures
\o /dev/null
TRUNCATE limit_runway_history;
CREATE SCHEMA lr_h;
-- A: 100 calls a day, three samples a day apart, sitting at 400 of 1000 (MAXVALUE 1000).
CREATE TABLE lr_h.a (id int PRIMARY KEY);
CREATE SEQUENCE lr_h.a_seq AS int MAXVALUE 1000 OWNED BY lr_h.a.id;
-- B: one sample only.
CREATE TABLE lr_h.b (id int PRIMARY KEY);
CREATE SEQUENCE lr_h.b_seq AS int MAXVALUE 1000 OWNED BY lr_h.b.id;
-- C: two samples, no movement.
CREATE TABLE lr_h.c (id int PRIMARY KEY);
CREATE SEQUENCE lr_h.c_seq AS int MAXVALUE 1000 OWNED BY lr_h.c.id;
-- D: moves, then is set back: a new epoch.
CREATE TABLE lr_h.d (id int PRIMARY KEY);
CREATE SEQUENCE lr_h.d_seq AS int MAXVALUE 1000 OWNED BY lr_h.d.id;
-- E: a slow week, then a fast last day.
CREATE TABLE lr_h.e (id int PRIMARY KEY);
CREATE SEQUENCE lr_h.e_seq AS int MAXVALUE 1000 OWNED BY lr_h.e.id;
-- F: under the 10% threshold.
CREATE TABLE lr_h.f (id int PRIMARY KEY);
CREATE SEQUENCE lr_h.f_seq AS int MAXVALUE 1000 OWNED BY lr_h.f.id;
-- G: only 20% used, below the view's 50%, but running out within the date window.
CREATE TABLE lr_h.g (id int PRIMARY KEY);
CREATE SEQUENCE lr_h.g_seq AS int MAXVALUE 1000 OWNED BY lr_h.g.id;

-- Day -2
SELECT setval('lr_h.a_seq', 200), setval('lr_h.c_seq', 300), setval('lr_h.d_seq', 300),
       setval('lr_h.f_seq', 50),  setval('lr_h.g_seq', 100);
SELECT * FROM limit_runway_sample(now() - interval '2 days');
-- Day -1
SELECT setval('lr_h.a_seq', 300), setval('lr_h.d_seq', 500), setval('lr_h.g_seq', 150);
SELECT * FROM limit_runway_sample(now() - interval '1 day');
-- Day 0: A on, B first seen, C unchanged, D set BACK, G on.
SELECT setval('lr_h.a_seq', 400), setval('lr_h.b_seq', 600), setval('lr_h.d_seq', 350),
       setval('lr_h.g_seq', 200);
CREATE TEMP TABLE s0 AS SELECT * FROM limit_runway_sample(now());

CREATE TEMP TABLE f AS SELECT * FROM limit_runway_findings(0.1);
CREATE TEMP TABLE fd AS SELECT * FROM limit_runway_findings();
CREATE TEMP TABLE ha AS SELECT array_agg(position ORDER BY sampled_at) AS p FROM limit_runway_history WHERE object = 'lr_h.a.id';
CREATE TEMP TABLE hd AS SELECT array_agg(epoch ORDER BY sampled_at) AS e FROM limit_runway_history WHERE object = 'lr_h.d.id';

-- E, on its own timeline, after the first block is read and the history emptied: every sample also
-- samples every key already in the table, so E's instants would otherwise land in A to G's series.
-- 100 seven days back, 165 half a day back, 215 now.
TRUNCATE limit_runway_history;
SELECT setval('lr_h.e_seq', 100);
SELECT * FROM limit_runway_sample(now() - interval '7 days');
SELECT setval('lr_h.e_seq', 165);
SELECT * FROM limit_runway_sample(now() - interval '12 hours');
SELECT setval('lr_h.e_seq', 215);
SELECT * FROM limit_runway_sample(now() + interval '1 second');
CREATE TEMP TABLE fe AS SELECT * FROM limit_runway_findings(0.1);
\o

-- ---------------------------------------------------------------- a date from two or more samples
SELECT is((SELECT p FROM ha), ARRAY[200, 300, 400]::numeric[],
          'the position is calls of nextval() used: 200, 300, 400, a day apart');
SELECT is((SELECT state || ' ' || rank_class FROM f WHERE object = 'lr_h.a.id'), 'projected 2',
          'two or more samples that moved give a projected date, ranked with the dates');
SELECT is((SELECT until_date FROM f WHERE object = 'lr_h.a.id'), now() + interval '6 days',
          '600 calls left at 100 a day is six days after the newest sample');
SELECT ok((SELECT detail FROM f WHERE object = 'lr_h.a.id') LIKE '%at 100 per day, from 3 samples over 2 days, it runs out about%',
          'and the detail says the rate, how many samples, and over what span');
SELECT ok((SELECT "then" FROM f WHERE object = 'lr_h.a.id')::text LIKE '%failed inserts included%',
          'with the error band the tool cannot narrow');

-- ---------------------------------------------------------------- no date without two samples that moved
SELECT is((SELECT state || ' ' || rank_class FROM f WHERE object = 'lr_h.b.id'), 'no rate yet 3',
          'one sample is "no rate yet"');
SELECT ok((SELECT detail FROM f WHERE object = 'lr_h.b.id') LIKE '%one sample so far, and a rate needs two',
          'and says why');
SELECT is((SELECT state || ' ' || coalesce(until_date::text, 'no date') FROM f WHERE object = 'lr_h.c.id'),
          'not moving no date', 'two samples with no movement are "not moving", and get no date');

-- ---------------------------------------------------------------- a break in the series
SELECT is((SELECT e FROM hd), ARRAY[0, 0, 1], 'a sequence set back starts a new epoch');
SELECT is((SELECT state FROM f WHERE object = 'lr_h.d.id'), 'no rate yet',
          'and the rate is fitted within the new epoch only, which has one sample, so no rate yet');
SELECT ok((SELECT detail FROM f WHERE object = 'lr_h.d.id') LIKE '%when the series restarted',
          'and the detail says the series restarted');
SELECT is((SELECT count(*)::int FROM f WHERE object = 'lr_h.d.id' AND until_date IS NOT NULL), 0,
          'never a rate fitted across the reset, which here would have been negative');

-- ---------------------------------------------------------------- two rates that disagree
SELECT ok((SELECT detail FROM fe WHERE object = 'lr_h.e.id') LIKE '%the last 24 hours ran at 100 per day, which gives%',
          'a 24-hour rate more than twice the 7-day one is given beside it, not instead of it');
SELECT is((SELECT until_date FROM fe WHERE object = 'lr_h.e.id'),
          (SELECT until_24h FROM limit_runway_projection('sequence', 'lr_h.e.id')),
          'and the row is ranked by the sooner date, the 24-hour one');
SELECT is((SELECT round(rate_24h) FROM limit_runway_projection('sequence', 'lr_h.e.id')), 100::numeric,
          '50 calls in the last half day is 100 a day');

-- ---------------------------------------------------------------- the threshold, and its exception
SELECT is((SELECT count(*)::int FROM limit_runway_history WHERE object = 'lr_h.f.id'), 0,
          'a sequence 5% used is not sampled');
SELECT ok((SELECT below_threshold FROM s0 WHERE kind = 'sequence') >= 1,
          'and is counted below the threshold in what the sampler returns');
\o /dev/null
SELECT setval('lr_h.a_seq', 50);
SELECT * FROM limit_runway_sample(now() + interval '2 seconds');
\o
SELECT is((SELECT epoch FROM limit_runway_history WHERE object = 'lr_h.a.id' ORDER BY sampled_at DESC LIMIT 1), 1,
          'a sequence already in the table is sampled even below the threshold, so its reset is seen');

-- ---------------------------------------------------------------- a date can bring a row in
SELECT is((SELECT state FROM fd WHERE object = 'lr_h.g.id'), 'projected',
          'a sequence 20% used, below the view''s 50%, is listed because it runs out within the window');

-- ---------------------------------------------------------------- the sampler''s rights
\o /dev/null
CREATE ROLE lr_h_reader;
GRANT EXECUTE ON FUNCTION limit_runway_findings(numeric, interval), limit_runway_sample(timestamptz) TO lr_h_reader;
CREATE ROLE lr_h_sampler;
GRANT EXECUTE ON FUNCTION limit_runway_sample(timestamptz) TO lr_h_sampler;
GRANT SELECT, INSERT ON limit_runway_history TO lr_h_sampler;
GRANT USAGE ON SCHEMA lr_h TO lr_h_sampler;
\o
SET ROLE lr_h_reader;
SELECT throws_ok('SELECT * FROM limit_runway_sample()', '42501',
                 'limit_runway_sample() needs SELECT and INSERT on limit_runway_history; nothing was sampled',
                 'without INSERT on the history the sampler refuses, and says which grant');
RESET ROLE;
SET ROLE lr_h_sampler;
\o /dev/null
CREATE TEMP TABLE s_low AS SELECT * FROM limit_runway_sample(now() + interval '3 seconds');
\o
RESET ROLE;
SELECT ok((SELECT not_established FROM s_low WHERE kind = 'sequence') >= 7,
          'a role that cannot read the sequences counts them as not established');
SELECT is((SELECT count(*)::int FROM limit_runway_history
            WHERE object LIKE 'lr_h.%' AND sampled_at = now() + interval '3 seconds'), 0,
          'and records nothing for them: a series is never pulled down by a role that saw less');

-- ---------------------------------------------------------------- invariants
SELECT is((SELECT count(*)::int FROM f WHERE state = 'projected' AND until_date IS NULL), 0,
          'every projected row has a date');
SELECT is((SELECT count(*)::int FROM f WHERE used_fraction < 0 OR used_fraction > 1), 0,
          'no share used outside 0..1, with history as without');
SELECT is((SELECT count(*)::int FROM f WHERE state IN ('exhausted', 'behind the data', 'cycled into existing keys')
             AND rank_class <> 1), 0,
          'a state that is failing now is never projected over');

-- ---------------------------------------------------------------- pruning
\o /dev/null
INSERT INTO limit_runway_history VALUES (now() - interval '40 days', 'sequence', 'lr_h.old', 1, 10, 0);
\o
SELECT is(limit_runway_prune(), 1::bigint, 'limit_runway_prune() forgets what is older than 35 days');
SELECT is((SELECT count(*)::int FROM limit_runway_history WHERE object = 'lr_h.a.id'), 4,
          'and keeps everything newer');

SELECT * FROM finish();
ROLLBACK;
