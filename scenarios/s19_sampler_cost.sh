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
# A small bound, not exactly 1: concurrent backends (autovacuum most likely) can take an xid between
# the two reads. The sampler's own cost is one INSERT, and an O(n) sampler would be ~10,000, so a
# bound of 5 keeps the O(1)-not-O(n) claim with a wide margin and does not flake on a busy server.
assert_true "one sample consumed a handful of transaction ids, the sampler's INSERT and any concurrent backend's, not one per sequence" \
  "$(awk "BEGIN { print ($xdiff >= 1 && $xdiff <= 5) ? \"t\" : \"f\" }")"
assert_true "and took under 30 seconds over 10,000 sequences" "$(awk "BEGIN { print ($secs < 30) ? \"t\" : \"f\" }")"
say "expected finding"
note "100 sampled, 9,900 below the threshold, O(1) xids consumed, and well under the bound."
