-- test/03_notify.sql: the Detect stage (0.3, docs/command.md).
--
-- The five geometric edges, the three tier labels' ladder, and the silence that a
-- notify-on-every-sample function fails. Written before limit_runway_notify() exists, so it fails
-- loudly until it does; it asserts the contract, not an implementation.
--
-- The ladder is driven by re-planting history whose slope lands until_date at a chosen distance, the
-- same arithmetic s15 and test/02_history.sql use: a sequence at MAXVALUE 100000 moving 100 a day has
-- 100 * days_out values left, so it runs out exactly days_out after the newest sample. The whole file
-- runs in one transaction, so now() is one instant and every date is exact.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pg_limit_runway;
\o
SELECT plan(25);

-- ---------------------------------------------------------------- the objects
SELECT has_table('limit_runway_alert', 'the alert state table exists');
SELECT col_is_pk('limit_runway_alert', ARRAY['channel', 'subject'],
                 'one row per subject per channel, the dedup key the contract fixes');
SELECT has_function('limit_runway_notify', ARRAY['text', 'interval', 'numeric'],
                    'limit_runway_notify(channel, within, min_used) exists');
SELECT has_function('limit_runway_notify_resolved', ARRAY['text', 'interval', 'numeric'],
                    'limit_runway_notify_resolved(channel, within, min_used) exists');
SELECT has_function('limit_runway_urgency', ARRAY['integer', 'timestamp with time zone', 'numeric', 'interval'],
                    'limit_runway_urgency(rank_class, until_date, used_fraction, within) exists');
SELECT ok(NOT has_function_privilege('public', 'limit_runway_notify(text,interval,numeric)', 'EXECUTE')
          AND NOT has_function_privilege('public', 'limit_runway_notify_resolved(text,interval,numeric)', 'EXECUTE'),
          'neither sender is executable by PUBLIC');

-- ---------------------------------------------------------------- the fixture, and a way to move it
--
-- plant(20) puts the date at now() + 20 days: an int sequence at MAXVALUE 100000, moved 100 a day over
-- three samples, with 2000 values left. It is re-planted between calls so the date is exact each time;
-- the alert table is NOT truncated, because that is the state under test.
\o /dev/null
CREATE SCHEMA lr_n;
CREATE TABLE lr_n.orders (id int PRIMARY KEY);
CREATE SEQUENCE lr_n.orders_seq AS int MAXVALUE 100000 OWNED BY lr_n.orders.id;
CREATE FUNCTION pg_temp.plant(days_out numeric) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  TRUNCATE limit_runway_history;
  PERFORM setval('lr_n.orders_seq', ((100000 - 100 * days_out) - 200)::bigint);
  PERFORM limit_runway_sample(now() - interval '2 days');
  PERFORM setval('lr_n.orders_seq', ((100000 - 100 * days_out) - 100)::bigint);
  PERFORM limit_runway_sample(now() - interval '1 day');
  PERFORM setval('lr_n.orders_seq', (100000 - 100 * days_out)::bigint);
  PERFORM limit_runway_sample(now());
END $$;
SELECT pg_temp.plant(20);
\o
SELECT is((SELECT until_date FROM limit_runway_findings() WHERE object = 'lr_n.orders.id'),
          now() + interval '20 days', 'the fixture runs out exactly 20 days out, so the ladder is exact');

-- The urgency ladder itself, called directly, so the mapping is checked and not inferred from counts.
SELECT is(limit_runway_urgency(2, now() + interval '20 days', NULL, interval '30 days'), 2,
          '20 days out, inside the window, is urgency 2, the onset edge');
SELECT is(limit_runway_urgency(2, now() + interval '12 hours', NULL, interval '30 days'), 6,
          'under a day is urgency 6, the last edge');

-- ---------------------------------------------------------------- onset, and the silence that matters
SELECT is(limit_runway_notify(), 1::bigint, 'a limit 20 days out is an onset');
SELECT is((SELECT count(*)::int FROM limit_runway_alert WHERE subject = 'sequence lr_n.orders.id'), 1,
          'and it writes one row of state for that subject');
SELECT is(limit_runway_notify(), 0::bigint, 'called again with the date unmoved, it is silent');
\o /dev/null
SELECT pg_temp.plant(18);
\o
SELECT is(limit_runway_notify(), 0::bigint,
          'a date that moved but is still above the next edge is silent: closer is not worse yet');

-- ---------------------------------------------------------------- one escalation per edge
\o /dev/null
SELECT pg_temp.plant(10);
\o
SELECT is(limit_runway_notify(), 1::bigint, 'under 15 days it escalates once');
\o /dev/null
SELECT pg_temp.plant(6);
\o
SELECT is(limit_runway_notify(), 1::bigint, 'under 7 days it escalates once');
\o /dev/null
SELECT pg_temp.plant(2);
\o
SELECT is(limit_runway_notify(), 1::bigint, 'under 3 days it escalates once');
\o /dev/null
SELECT pg_temp.plant(0.5);
\o
SELECT is(limit_runway_notify(), 1::bigint, 'under 1 day it escalates once');
SELECT is(limit_runway_notify(), 0::bigint, 'and then it is silent again at the same edge');
SELECT is((SELECT subject FROM limit_runway_alert WHERE subject = 'sequence lr_n.orders.id'),
          'sequence lr_n.orders.id',
          'the subject is stable and names the limit, which pairs an escalation with its onset');

-- ---------------------------------------------------------------- clearing, and a relapse
\o /dev/null
SELECT pg_temp.plant(100);
\o
SELECT is(limit_runway_notify_resolved(), 1::bigint, 'a limit more than 30 days out has cleared');
SELECT is(limit_runway_notify_resolved(), 0::bigint, 'and clearing a second time says nothing');
SELECT is((SELECT count(*)::int FROM limit_runway_alert WHERE subject = 'sequence lr_n.orders.id'), 0,
          'the state is forgotten when it clears');
\o /dev/null
SELECT pg_temp.plant(20);
\o
SELECT is(limit_runway_notify(), 1::bigint,
          'the same limit approaching again alerts from onset, not against the old high-water mark');

-- ---------------------------------------------------------------- the payload carries what the family needs
SELECT ok((SELECT prosrc FROM pg_proc WHERE proname = 'limit_runway_notify') LIKE '%escalated%',
          'the sender distinguishes escalation, which this tool has a discrete edge for');
SELECT ok((SELECT prosrc FROM pg_proc WHERE proname = 'limit_runway_notify') LIKE '%sampled_at%',
          'and carries sampled_at, one of the required keys');

SELECT * FROM finish();
ROLLBACK;
