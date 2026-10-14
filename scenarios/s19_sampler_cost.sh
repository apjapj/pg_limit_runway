#!/usr/bin/env bash
# s19 (0.2): what a sample costs, measured before 0.2 ships (docs/history.md).
#   10,000 sequences, 100 of them past the 10% threshold. The sampler must read every one, record
#   only the 100, and take O(1) transaction ids per call rather than O(n). The measurement is the
#   server-wide xmax across the sample (s5: reading the current xid through the snapshot assigns
#   none), so it is an upper bound on what the sampler itself consumed, not an isolation of it: a
#   concurrent autovacuum or any other backend can also take an xid between the two reads. That is
#   why the claim is a bound and not a number. An O(n) implementation would show ~10,000, so a
#   bound of a few still separates O(1) from O(n) with a wide margin, and does not fail at random
#   when the server is busy. The time is recorded in out/, not in the
#   evidence, because it varies; the evidence keeps the bound it was checked against.
. "$(dirname "$0")/lib.sh"
setup_schema
use_extension || skip "pg_limit_runway is not installed on this server"
psql_q -c "DO \$d\$ BEGIN FOR i IN 1..10000 LOOP
             EXECUTE format('CREATE SEQUENCE $SCHEMA.s19_%s AS int MAXVALUE 1000', i);
           END LOOP; END \$d\$" \
       -c "SELECT count(setval(format('$SCHEMA.s19_%s', i), 500)) FROM generate_series(1, 100) i" >/dev/null

say "one sample over 10,000 sequences"
x0=$(val "SELECT pg_snapshot_xmax(pg_current_snapshot())::text::bigint")
t0=$(date +%s.%N)
res=$(val "SELECT sampled || '/' || below_threshold FROM limit_runway_sample() WHERE kind = 'sequence'")
t1=$(date +%s.%N)
x1=$(val "SELECT pg_snapshot_xmax(pg_current_snapshot())::text::bigint")
secs=$(awk "BEGIN { printf \"%.2f\", $t1 - $t0 }")
xdiff=$((x1 - x0))
mkdir -p "$(dirname "$0")/out"; echo "sample over 10,000 sequences took $secs s" > "$(dirname "$0")/out/s19_sample_time.txt"
note "sequences sampled / below the threshold: $res"
# The xid delta is deliberately NOT echoed: it is a server-wide counter, so it varies run to run,
# and printing it would make the evidence non-deterministic. The assertion below checks it.

say "checks"
assert_true "the 100 past 10% are sampled and the other 9,900 are not" "$([ "$res" = "100/9900" ] && echo t || echo f)"
# A bound, not exactly 1, and the bound is generous on purpose. The two reads are of a server-wide
# counter, so the figure includes every other backend that took an xid in between, and this fixture
# creates 10,000 sequences, which wakes autovacuum: a bound of 5 was too tight and failed in CI on a
# run whose assertions were all passing. The number is now large enough to survive that and still say
# what this scenario exists to say, because an O(n) sampler would consume roughly 10,000, one per
# sequence, which is an order of magnitude above this bound rather than a few counts above it.
#
# The observed value is written to out/, NOT to the evidence, for the same reason the time is: it
# varies run to run. It is there so that a future failure of this assertion can be read rather than
# guessed at, which is what the first failure cost.
BOUND=1000
echo "xids consumed across one sample (server-wide, so others count too): $xdiff" \
    > "$(dirname "$0")/out/s19_xid_cost.txt"
# The number is deliberately NOT in the message: assert_true's text goes into the evidence, and the
# figure varies run to run, which is the same reason the time is kept out of it. It was in the first
# draft of this change and would have made the evidence differ on every run.
assert_true "one sample consumed a bounded number of transaction ids, not one per sequence" \
  "$(awk "BEGIN { print ($xdiff >= 1 && $xdiff <= $BOUND) ? \"t\" : \"f\" }")"
assert_true "and took under 30 seconds over 10,000 sequences" "$(awk "BEGIN { print ($secs < 30) ? \"t\" : \"f\" }")"
say "expected finding"
note "100 sampled, 9,900 below the threshold, O(1) xids consumed, and well under the bound."
