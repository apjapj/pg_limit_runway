#!/usr/bin/env bash
# s15 (0.2): a date from samples, on one timeline with a fixed date.
#   s15_orders.id: MAXVALUE 1000, consumed for real by inserts, 100 a day, sampled a day apart at 150,
#                  250 and 350 calls used. 650 calls left at 100 a day is six and a half days.
#   lr_scen_s15:   a password expiring in three days: a fixed date, which must sort BEFORE the
#                  projected one, because ranking.md puts every date on one timeline.
# The samples are laid down at instants relative to one BASE, so the rate and the date are exact.
. "$(dirname "$0")/lib.sh"
setup_schema
use_extension || skip "pg_limit_runway is not installed on this server"
take_base
psql_q -c "CREATE SEQUENCE $SCHEMA.s15_orders_seq AS int MAXVALUE 1000" \
       -c "CREATE TABLE $SCHEMA.s15_orders (id int PRIMARY KEY DEFAULT nextval('$SCHEMA.s15_orders_seq'), v int)" \
       -c "ALTER SEQUENCE $SCHEMA.s15_orders_seq OWNED BY $SCHEMA.s15_orders.id" \
       -c "INSERT INTO $SCHEMA.s15_orders (v) SELECT g FROM generate_series(1, 150) g" \
       -c "CREATE ROLE lr_scen_s15 LOGIN PASSWORD 'test' VALID UNTIL '$(val "SELECT ('$BASE'::timestamptz + interval '3 days')::text")'" >/dev/null

say "three samples, a day apart, with 100 real inserts between each"
note "two days back: $(sample_at '2 days') limit(s) sampled"
psql_q -c "INSERT INTO $SCHEMA.s15_orders (v) SELECT g FROM generate_series(1, 100) g" >/dev/null
note "one day back:  $(sample_at '1 day') limit(s) sampled"
psql_q -c "INSERT INTO $SCHEMA.s15_orders (v) SELECT g FROM generate_series(1, 100) g" >/dev/null
note "now:           $(sample_at '0') limit(s) sampled"
psql -X -P pager=off -c "
SELECT extract(epoch FROM sampled_at - '$BASE'::timestamptz) / 86400 AS day, position, limit_value, epoch
  FROM limit_runway_history WHERE object = '$SCHEMA.s15_orders.id' ORDER BY sampled_at"

finding "$SCHEMA.s15_%"
finding "role lr_scen_s15"

say "checks"
assert_true "the position is calls used: 150, 250, 350" "$(val "SELECT array_agg(position ORDER BY sampled_at) = '{150,250,350}' FROM limit_runway_history WHERE object = '$SCHEMA.s15_orders.id'")"
assert_true "100 calls a day over the two days" "$(val "SELECT rate_7d = 100 FROM limit_runway_projection('sequence', '$SCHEMA.s15_orders.id')")"
assert_true "650 calls left is six and a half days after the newest sample" "$(val "SELECT until_7d - newest_at = interval '6 days 12 hours' FROM limit_runway_projection('sequence', '$SCHEMA.s15_orders.id')")"
assert_finding $SCHEMA.s15_orders.id projected '%failed inserts included%' '' '650 of 1000 values left%at 100 per day, from 3 samples over 2 days, it runs out about%' 2
assert_ranked_before 'role lr_scen_s15' $SCHEMA.s15_orders.id
say "expected finding"
note "s15_orders.id: projected, class 2, about six and a half days out, with the rate and the error band."
note "The password three days out sorts before it: fixed and projected dates share one timeline."
