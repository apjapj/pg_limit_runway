#!/usr/bin/env bash
# s5: transaction ID age. Three thresholds, and the README's warning about measuring it:
#   - reading the current xid with pg_current_xact_id() ASSIGNS one, so a monitor that samples that way
#     consumes the resource it measures; pg_snapshot_xmax(pg_current_snapshot()) does not;
#   - autovacuum_freeze_max_age forces an anti-wraparound vacuum, even on a table with autovacuum off;
#   - vacuum_failsafe_age and the hard stop are distances that cannot be reached here (billions of xids),
#     so they are reported as the distances a tool would compute, not observed.
. "$(dirname "$0")/lib.sh"
setup_schema

say "reading the current xid: which way consumes one"
a=$(val "SELECT pg_snapshot_xmax(pg_current_snapshot())"); b=$(val "SELECT pg_snapshot_xmax(pg_current_snapshot())")
c=$(val "SELECT pg_current_xact_id()"); d=$(val "SELECT pg_snapshot_xmax(pg_current_snapshot())")
assert_true "two reads of pg_snapshot_xmax(pg_current_snapshot()) assign nothing" "$([ "$a" = "$b" ] && echo t || echo f)"
assert_true "one call of pg_current_xact_id() assigns an xid" "$([ "$d" -gt "$b" ] && echo t || echo f)"

say "the forced vacuum: two tables with autovacuum OFF and autovacuum_freeze_max_age 100000 (the lowest allowed)"
# s5_ledger keeps the default freeze_min_age (50 million); s5_ledger_fmin0 sets it to 0. The difference
# is the point: a forced vacuum freezes only rows older than freeze_min_age, so on the first table it
# runs and relfrozenxid barely moves, which the first draft of this scenario assumed it would.
psql_q -c "CREATE TABLE $SCHEMA.s5_ledger (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false, autovacuum_freeze_max_age = 100000)" \
       -c "CREATE TABLE $SCHEMA.s5_ledger_fmin0 (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false, autovacuum_freeze_max_age = 100000, autovacuum_freeze_min_age = 0)" \
       -c "INSERT INTO $SCHEMA.s5_ledger SELECT g, 'x' FROM generate_series(1, 1000) g" \
       -c "INSERT INTO $SCHEMA.s5_ledger_fmin0 SELECT g, 'x' FROM generate_series(1, 1000) g" \
       -c "CREATE PROCEDURE $SCHEMA.burn(n int) LANGUAGE plpgsql AS \$\$ BEGIN FOR i IN 1..n LOOP PERFORM pg_current_xact_id(); COMMIT; END LOOP; END \$\$" \
       -c "CALL $SCHEMA.burn(110000)"
assert_true "age(relfrozenxid) passed the table's autovacuum_freeze_max_age of 100000" "$(val "SELECT age(relfrozenxid) > 100000 FROM pg_class WHERE oid = '$SCHEMA.s5_ledger'::regclass")"
wait_for "(SELECT count(*) = 2 FROM pg_stat_user_tables WHERE relname IN ('s5_ledger', 's5_ledger_fmin0') AND autovacuum_count >= 1)" 120 "an anti-wraparound autovacuum of both tables"
wait_for "(SELECT age(relfrozenxid) < 100000 FROM pg_class WHERE oid = '$SCHEMA.s5_ledger_fmin0'::regclass)" 60 "s5_ledger_fmin0's relfrozenxid to advance"
assert_true "an anti-wraparound autovacuum ran on both, although autovacuum_enabled = false" "$(val "SELECT count(*) = 2 FROM pg_stat_user_tables WHERE relname IN ('s5_ledger', 's5_ledger_fmin0') AND autovacuum_count >= 1")"
assert_true "with the default freeze_min_age it froze nothing: s5_ledger's age is still over 100000" "$(val "SELECT age(relfrozenxid) > 100000 FROM pg_class WHERE oid = '$SCHEMA.s5_ledger'::regclass")"
assert_true "with freeze_min_age 0 it froze the table: s5_ledger_fmin0's age fell under 100000" "$(val "SELECT age(relfrozenxid) < 100000 FROM pg_class WHERE oid = '$SCHEMA.s5_ledger_fmin0'::regclass")"

say "the usual check, and the distances a tool would report (this database)"
psql -X -P pager=off -c "
SELECT datname,
       age(datfrozenxid) > 0 AS age_readable,
       current_setting('autovacuum_freeze_max_age')::bigint AS autovacuum_freeze_max_age,
       current_setting('vacuum_failsafe_age')::bigint AS vacuum_failsafe_age,
       2147483648 AS wraparound
  FROM pg_database WHERE datname = current_database()"
say "expected finding"
note "XID age is the database's age(datfrozenxid), read without assigning an xid. The forced vacuum starts at"
note "autovacuum_freeze_max_age and ignores autovacuum_enabled = false. But it only freezes rows older than"
note "vacuum_freeze_min_age, so a forced vacuum running is not the same as age falling: a tool must read the"
note "age after the vacuum, not assume the vacuum fixed it. The failsafe (vacuum_failsafe_age) and the stop"
note "before 2^31 are reported as distances, not observed here."
