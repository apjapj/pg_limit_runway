#!/usr/bin/env bash
# s16 (0.2): a break in a series. A rate fitted across a reset is nonsense, and here it would be negative.
#   s16_items.id:  200, 300 calls used a day apart, then RESTORED to 100 (setval backwards, as a restore
#                  without its sequence would leave it), then 150 a day later. A new epoch starts at the
#                  restore, and the rate comes from the two samples after it: 50 a day, not 300 to 150.
#   s16_wide.id:   MAXVALUE raised from 1000 to 2000 between two samples (the fix being made). The limit
#                  changed, so that also starts a new epoch, and one sample in it is "no rate yet".
. "$(dirname "$0")/lib.sh"
setup_schema
use_extension || skip "pg_limit_runway is not installed on this server"
take_base
psql_q -c "CREATE SEQUENCE $SCHEMA.s16_items_seq AS int MAXVALUE 1000" \
       -c "CREATE TABLE $SCHEMA.s16_items (id int PRIMARY KEY DEFAULT nextval('$SCHEMA.s16_items_seq'))" \
       -c "ALTER SEQUENCE $SCHEMA.s16_items_seq OWNED BY $SCHEMA.s16_items.id" \
       -c "CREATE SEQUENCE $SCHEMA.s16_wide_seq AS int MAXVALUE 1000" \
       -c "CREATE TABLE $SCHEMA.s16_wide (id int PRIMARY KEY DEFAULT nextval('$SCHEMA.s16_wide_seq'))" \
       -c "ALTER SEQUENCE $SCHEMA.s16_wide_seq OWNED BY $SCHEMA.s16_wide.id" >/dev/null

say "samples: on, on, set back, on"
psql_q -c "SELECT setval('$SCHEMA.s16_items_seq', 200), setval('$SCHEMA.s16_wide_seq', 500)" >/dev/null; sample_at '3 days' >/dev/null
psql_q -c "SELECT setval('$SCHEMA.s16_items_seq', 300), setval('$SCHEMA.s16_wide_seq', 600)" >/dev/null; sample_at '2 days' >/dev/null
psql_q -c "SELECT setval('$SCHEMA.s16_items_seq', 100)" -c "ALTER SEQUENCE $SCHEMA.s16_wide_seq MAXVALUE 2000" >/dev/null; sample_at '1 day' >/dev/null
psql_q -c "SELECT setval('$SCHEMA.s16_items_seq', 150)" >/dev/null; sample_at '0' >/dev/null
psql -X -P pager=off -c "
SELECT object, extract(epoch FROM sampled_at - '$BASE'::timestamptz) / 86400 AS day, position, limit_value, epoch
  FROM limit_runway_history WHERE object LIKE '$SCHEMA.s16_%' ORDER BY object, sampled_at"

finding "$SCHEMA.s16_%"

say "checks"
assert_true "the restore starts a new epoch: 0, 0, 1, 1" "$(val "SELECT array_agg(epoch ORDER BY sampled_at) = '{0,0,1,1}' FROM limit_runway_history WHERE object = '$SCHEMA.s16_items.id'")"
assert_true "the rate is the 50 a day since the restore, from its two samples" "$(val "SELECT samples = 2 AND rate_7d = 50 FROM limit_runway_projection('sequence', '$SCHEMA.s16_items.id')")"
assert_true "a slope across the restore would have been negative: 300 to 150 in two days" "$(val "SELECT (150 - 300) / 2.0 < 0")"
assert_true "a changed limit starts a new epoch too" "$(val "SELECT array_agg(epoch ORDER BY sampled_at) = '{0,0,1,1}' FROM limit_runway_history WHERE object = '$SCHEMA.s16_wide.id'")"
assert_finding $SCHEMA.s16_items.id projected '%failed inserts included%' '' '%at 50 per day, from 2 samples over 1 day,%when the series restarted' 2
say "expected finding"
note "s16_items.id: projected from the 2 samples since the restore at 50 a day, and saying the series"
note "restarted. Never a rate across the reset. s16_wide.id: the new limit starts a new series."
