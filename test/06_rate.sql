-- test/06_rate.sql: limit_runway_rate() exposes both slopes and the disagreement.
--
-- The finding carries one date. This function answers why that date was chosen and shows the other
-- slope when the 7-day and 24-hour rates disagree by more than a factor of two.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pg_limit_runway;

DELETE FROM limit_runway_history WHERE object LIKE 'public.lr_rate_%';

INSERT INTO limit_runway_history (sampled_at, kind, object, position, limit_value, epoch)
VALUES
  (now() - interval '8 days', 'sequence', 'public.lr_rate_disagree',   0, 1000, 0),
  (now() - interval '7 days', 'sequence', 'public.lr_rate_disagree',  30, 1000, 0),
  (now() - interval '1 day',  'sequence', 'public.lr_rate_disagree',  20, 1000, 0),
  (now(),                     'sequence', 'public.lr_rate_disagree', 100, 1000, 0),
  (now() - interval '2 days', 'sequence', 'public.lr_rate_flat',      50, 1000, 2),
  (now() - interval '1 day',  'sequence', 'public.lr_rate_flat',      50, 1000, 2),
  (now(),                     'sequence', 'public.lr_rate_flat',      50, 1000, 2),
  (now(),                     'sequence', 'public.lr_rate_one',       10, 1000, 0);
\o
\unset QUIET

SELECT plan(10);

SELECT has_function('limit_runway_rate', ARRAY['text', 'text'],
                    'limit_runway_rate(text, text) exists');
SELECT is((SELECT samples FROM limit_runway_rate('sequence', 'public.lr_rate_disagree')), 4::bigint,
          'four samples in the newest epoch');
SELECT is((SELECT rate_source FROM limit_runway_rate('sequence', 'public.lr_rate_disagree')), 'disagree',
          'the two slopes are more than a factor of two apart');
SELECT ok((SELECT disagree FROM limit_runway_rate('sequence', 'public.lr_rate_disagree')),
          'and the disagreement flag says so');
SELECT is((SELECT until_date FROM limit_runway_rate('sequence', 'public.lr_rate_disagree')),
          (SELECT least(until_7d, until_24h)
             FROM limit_runway_rate('sequence', 'public.lr_rate_disagree')),
          'the date used is the sooner of the two');
SELECT is((SELECT rate_source FROM limit_runway_rate('sequence', 'public.lr_rate_flat')), 'flat',
          'a series that does not move is flat, not a date');
SELECT is((SELECT epoch FROM limit_runway_rate('sequence', 'public.lr_rate_flat')), 2,
          'the newest epoch is the one read');
SELECT is((SELECT rate_source FROM limit_runway_rate('sequence', 'public.lr_rate_one')), 'none',
          'one sample has no rate yet');
SELECT is((SELECT count(*)::int FROM limit_runway_rate('sequence', 'public.lr_rate_missing')), 0,
          'a never-sampled series returns no row');
SELECT ok(NOT has_function_privilege('public', 'limit_runway_rate(text,text)', 'EXECUTE'),
          'the rate reader is closed like the other readers');

\o /dev/null
DELETE FROM limit_runway_history WHERE object LIKE 'public.lr_rate_%';
\o
SELECT * FROM finish();
