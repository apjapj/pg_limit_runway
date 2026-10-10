#!/usr/bin/env bash
# s13: the two sequence shapes s3 does not reach. Raised by Piotr's review of 0.1: a descending CYCLE
# sequence, where a count of "values left" was suspected of printing the distance past the floor.
#   s13_ring:  descending, INCREMENT -1, MINVALUE 10 MAXVALUE 20, CYCLE, seven rows in (20 down to 14).
#   s13_step:  descending, INCREMENT -3, MINVALUE 10 MAXVALUE 21, no cycle, four rows in (21, 18, 15, 12):
#              at 12, 2 above its floor,
#              and its next call (9) is already past it.
# Measured, not assumed: the count is checked against the inserts that actually succeed before the wrap.
. "$(dirname "$0")/lib.sh"
setup_schema
psql_q -c "CREATE SEQUENCE $SCHEMA.s13_ring_seq AS int INCREMENT -1 MINVALUE 10 MAXVALUE 20 START 20 CYCLE" \
       -c "CREATE TABLE $SCHEMA.s13_ring (id int PRIMARY KEY DEFAULT nextval('$SCHEMA.s13_ring_seq'))" \
       -c "ALTER SEQUENCE $SCHEMA.s13_ring_seq OWNED BY $SCHEMA.s13_ring.id" \
       -c "INSERT INTO $SCHEMA.s13_ring SELECT FROM generate_series(1, 7)" \
       -c "CREATE SEQUENCE $SCHEMA.s13_step_seq AS int INCREMENT -3 MINVALUE 10 MAXVALUE 21 START 21" \
       -c "CREATE TABLE $SCHEMA.s13_step (id int PRIMARY KEY DEFAULT nextval('$SCHEMA.s13_step_seq'))" \
       -c "ALTER SEQUENCE $SCHEMA.s13_step_seq OWNED BY $SCHEMA.s13_step.id" \
       -c "INSERT INTO $SCHEMA.s13_step SELECT FROM generate_series(1, 4)" >/dev/null

say "the usual check (pg_sequences: last_value against the floor)"
psql -X -P pager=off -c "
SELECT sequencename, increment_by, min_value, max_value, cycle, last_value, last_value - min_value AS distance_to_floor
  FROM pg_sequences WHERE schemaname = '$SCHEMA' ORDER BY 1"

finding "$SCHEMA.s13_%"
ring_said=$(val "SELECT substring(detail from '^([0-9]+) of') FROM limit_runway_findings(0) WHERE object = '$SCHEMA.s13_ring.id'" 2>/dev/null)
assert_finding $SCHEMA.s13_ring.id 'no rate yet' '%cycles instead of failing%' '' '4 of 11 values left before it wraps to 20%' 3
assert_finding $SCHEMA.s13_step.id exhausted '' '' '%limit is 10, and the next call fails: 10 is the sequence%MINVALUE%' 1

say "what actually happens"
serr=$(try_sql "INSERT INTO $SCHEMA.s13_step DEFAULT VALUES")
note "s13_step, 2 above its floor: $serr"
n=$(val "DO \$\$ DECLARE n int := 0; BEGIN LOOP BEGIN INSERT INTO $SCHEMA.s13_ring DEFAULT VALUES; n := n + 1;
         EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'n=%', n; EXIT; END; END LOOP; END \$\$" 2>&1 | sed -n 's/.*n=//p')
note "s13_ring: $n inserts succeeded, then the sequence wrapped to $(val "SELECT last_value FROM pg_sequences WHERE sequencename = 's13_ring_seq'") and the insert collided"

say "checks"
assert_true "s13_step fails with 2 values between it and its floor, because its step is 3" "$([[ "$serr" == *"reached minimum value"* ]] && echo t || echo f)"
assert_true "s13_ring took 4 more inserts before the wrap: 13 down to 10" "$([ "$n" = 4 ] && echo t || echo f)"
[ -n "$ring_said" ] && assert_true "the count pg_limit_runway gave before, $ring_said, is the number of inserts that succeeded" "$([ "$ring_said" = "$n" ] && echo t || echo f)"

say "after the wrap"
finding "$SCHEMA.s13_ring%"
assert_finding $SCHEMA.s13_ring.id 'cycled into existing keys' '' '' '%sequence at 20, data at 10%the next default id, 19, is already taken%No setval fixes%' 1
use_extension && assert_true "after the wrap, s13_ring is given no count and no share used" "$(val "SELECT used_fraction IS NULL AND detail NOT LIKE '%values left%' FROM limit_runway_findings(0) WHERE object = '$SCHEMA.s13_ring.id'")"

say "expected finding"
note "s13_ring: before the wrap, 4 values left before it wraps to 20, the same number of inserts that then"
note "succeeded; after it, cycled into existing keys, with no count. s13_step: exhausted at 12, 2 above its"
note "floor, because the count is of calls of nextval() in steps of 3, not of values between it and the floor."
