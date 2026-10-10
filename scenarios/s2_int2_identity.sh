#!/usr/bin/env bash
# s2: an int2 identity column, which runs out first: 32,767 values. Run here all the way out.
. "$(dirname "$0")/lib.sh"
setup_schema
psql_q -c "CREATE TABLE $SCHEMA.s2_events (id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, x int)" \
       -c "INSERT INTO $SCHEMA.s2_events (x) SELECT g FROM generate_series(1, 32767) g" >/dev/null

say "the usual check (pg_sequences)"
psql -X -P pager=off -c "
SELECT sequencename, data_type, last_value, max_value, round(100.0 * last_value / max_value, 2) AS pct_used
  FROM pg_sequences WHERE schemaname = '$SCHEMA' AND sequencename LIKE 's2_events%'"

say "what actually happens: the next insert"
err=$(try_sql "INSERT INTO $SCHEMA.s2_events (x) VALUES (0)")
note "${err:-(no error)}"

say "checks"
assert_true "the identity sequence is smallint, created to match the column" "$(val "SELECT data_type = 'smallint'::regtype FROM pg_sequences WHERE sequencename LIKE 's2_events%'")"
assert_true "32767 rows went in" "$(val "SELECT count(*) = 32767 FROM $SCHEMA.s2_events")"
assert_true "the next insert fails at the sequence's maximum" "$([[ "$err" == *"reached maximum value"* ]] && echo t || echo f)"
say "expected finding"
note "s2_events.id (int2 identity): 0 of 32767 values left. Here the usual check is right (100%), because an"
note "identity sequence is created with the column's type; the trap is only that int2 runs out at 32767."
