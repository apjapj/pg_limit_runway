#!/usr/bin/env bash
# s3: three sequences whose limit is not "max_value of the type":
#   a) a descending sequence (INCREMENT -1), which runs out at min_value, not max_value;
#   b) a custom MAXVALUE on a bigint column, where the limit is the MAXVALUE, not the type;
#   c) CYCLE, where nextval() never fails: it wraps, and the INSERT collides with an existing key.
. "$(dirname "$0")/lib.sh"
setup_schema
psql_q -c "CREATE SEQUENCE $SCHEMA.s3_desc AS integer INCREMENT -1 START -1" \
       -c "SELECT setval('$SCHEMA.s3_desc', -2147483645)" \
       -c "CREATE SEQUENCE $SCHEMA.s3_capped AS bigint MAXVALUE 1000" \
       -c "CREATE TABLE $SCHEMA.s3_capped_t (id bigint PRIMARY KEY DEFAULT nextval('$SCHEMA.s3_capped'))" \
       -c "ALTER SEQUENCE $SCHEMA.s3_capped OWNED BY $SCHEMA.s3_capped_t.id" \
       -c "SELECT setval('$SCHEMA.s3_capped', 1000)" \
       -c "CREATE SEQUENCE $SCHEMA.s3_cyc AS integer MAXVALUE 100 CYCLE" \
       -c "CREATE TABLE $SCHEMA.s3_cyc_t (id int PRIMARY KEY DEFAULT nextval('$SCHEMA.s3_cyc'))" \
       -c "ALTER SEQUENCE $SCHEMA.s3_cyc OWNED BY $SCHEMA.s3_cyc_t.id" \
       -c "INSERT INTO $SCHEMA.s3_cyc_t SELECT FROM generate_series(1, 100)" >/dev/null

say "the usual check (pg_sequences, last_value against max_value)"
psql -X -P pager=off -c "
SELECT sequencename, data_type, increment_by, min_value, max_value, cycle, last_value,
       round(100.0 * last_value / max_value, 2) AS pct_used
  FROM pg_sequences WHERE schemaname = '$SCHEMA' ORDER BY 1"

finding "lr_scen.s3_%"
assert_finding lr_scen.s3_desc 'no rate yet' '' '' '3 of 2147483648 values left%descending%' 3
assert_finding lr_scen.s3_capped_t.id exhausted '%MAXVALUE 1000, not the column%' '' '%limit is 1000%' 1
assert_finding lr_scen.s3_cyc_t.id 'no rate yet' '%cycles instead of failing%' '' '0 of 100 values left%' 3

say "what actually happens"
d1=$(val "SELECT nextval('$SCHEMA.s3_desc')"); d2=$(val "SELECT nextval('$SCHEMA.s3_desc')"); d3=$(val "SELECT nextval('$SCHEMA.s3_desc')")
derr=$(try_sql "SELECT nextval('$SCHEMA.s3_desc')")
note "a) descending: nextval gave $d1, $d2, $d3, then: $derr"
cerr=$(try_sql "INSERT INTO $SCHEMA.s3_capped_t DEFAULT VALUES")
note "b) MAXVALUE 1000 on a bigint column: $cerr"
cycv=$(val "SELECT nextval('$SCHEMA.s3_cyc')")
yerr=$(try_sql "INSERT INTO $SCHEMA.s3_cyc_t DEFAULT VALUES")
note "c) CYCLE: nextval did not fail, it returned $cycv; the insert then: $yerr"

say "checks"
assert_true "the descending sequence's usual pct_used is meaningless (above 100%)" "$(val "SELECT 100.0 * last_value / max_value > 100 FROM pg_sequences WHERE sequencename = 's3_desc'")"
assert_true "the descending sequence fails at its minimum" "$([[ "$derr" == *"reached minimum value"* ]] && echo t || echo f)"
assert_true "the capped sequence fails at MAXVALUE 1000, far below bigint's" "$([[ "$cerr" == *"reached maximum value"*"1000"* ]] && echo t || echo f)"
assert_true "the cycling sequence wrapped to 1 instead of failing" "$([ "$cycv" = 1 ] && echo t || echo f)"
assert_true "and the insert collided with an existing key" "$([[ "$yerr" == *"duplicate key value"* ]] && echo t || echo f)"
say "after: the descending sequence has run out, and the cycling one has wrapped into its data"
finding "lr_scen.s3_%"
assert_finding lr_scen.s3_desc exhausted '' '' '%limit is -2147483648, and the next value would be -2147483649' 1
assert_finding lr_scen.s3_cyc_t.id 'cycled into existing keys' '' '' '%sequence at 2, data at 100%the next default id, 3, is already taken%No setval fixes a cycling sequence%' 1
say "expected finding"
note "a) s3_desc: 3 values left, measured downwards to min_value. b) s3_capped: 0 left, the limit is"
note "MAXVALUE 1000, not bigint. c) s3_cyc: a different finding, not exhaustion: it has wrapped and every"
note "insert now collides with a key that exists."
