#!/usr/bin/env bash
# s19 (0.2): what a sample costs, measured before 0.2 ships (docs/history.md).
#   10,000 sequences, 100 of them past the 10% threshold. The sampler must read every one, record only
#   the 100, and consume exactly one transaction id per call, the INSERT's (s5: reading the current xid
#   through the snapshot assigns none). The time is recorded in out/, not in the evidence, because it
#   varies; the evidence keeps the bound it was checked against.
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
mkdir -p "$(dirname "$0")/out"; echo "sample over 10,000 sequences took $secs s" > "$(dirname "$0")/out/s19_sample_time.txt"
note "sequences sampled / below the threshold: $res"

say "checks"
assert_true "the 100 past 10% are sampled and the other 9,900 are not" "$([ "$res" = "100/9900" ] && echo t || echo f)"
assert_true "one sample consumed exactly one transaction id, the INSERT's" "$([ $((x1 - x0)) -eq 1 ] && echo t || echo f)"
assert_true "and took under 30 seconds over 10,000 sequences" "$(awk "BEGIN { print ($secs < 30) ? \"t\" : \"f\" }")"
say "expected finding"
note "100 sampled, 9,900 below the threshold, one xid consumed, and well under the bound."
