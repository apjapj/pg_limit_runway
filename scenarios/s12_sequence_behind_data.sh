#!/usr/bin/env bash
# s12: rows loaded with EXPLICIT ids, the sequence never advanced (a COPY or restore without setval). The
# sequence is not "nearly full": it is behind the data, and the very next default id collides. Measured
# first by Piotr: five explicit ids, last_value 1, a subtraction of -4 and a usual check of 500% used.
# Subtraction cannot measure this and the tool cannot fix it (advancing a sequence is a write), so the
# finding is a state with a named fix, not a projection.
. "$(dirname "$0")/lib.sh"
setup_schema
psql_q -c "CREATE TABLE $SCHEMA.s12_items (id serial PRIMARY KEY, name text)" \
       -c "INSERT INTO $SCHEMA.s12_items (id, name) SELECT g, 'loaded' FROM generate_series(1, 5) g" >/dev/null

say "the usual check (pg_sequences against the data)"
psql -X -P pager=off -c "
SELECT s.last_value, s.last_value IS NULL AS never_called, (SELECT max(id) FROM $SCHEMA.s12_items) AS max_id,
       round(100.0 * (SELECT max(id) FROM $SCHEMA.s12_items) / coalesce(s.last_value, s.start_value), 1) AS pct_used
  FROM pg_sequences s WHERE s.schemaname = '$SCHEMA' AND s.sequencename = 's12_items_id_seq'"

say "what actually happens: the next insert"
err=$(try_sql "INSERT INTO $SCHEMA.s12_items (name) VALUES ('next')")
note "${err:-(no error)}"

say "evidence: the state a tool reads, cheaply: max(id) through the primary key index, not a scan"
psql -X -P pager=off -c "EXPLAIN (COSTS OFF) SELECT max(id) FROM $SCHEMA.s12_items" | grep -iE 'index|seq scan' | sed 's/^/  /'
psql -X -P pager=off -c "
SELECT coalesce(s.last_value, s.start_value - 1) AS sequence_at, (SELECT max(id) FROM $SCHEMA.s12_items) AS data_at,
       coalesce(s.last_value, s.start_value - 1) < (SELECT max(id) FROM $SCHEMA.s12_items) AS sequence_behind_data
  FROM pg_sequences s WHERE s.schemaname = '$SCHEMA' AND s.sequencename = 's12_items_id_seq'"

say "checks"
assert_true "the usual check reports more than 100% used" "$(val "SELECT 100.0 * (SELECT max(id) FROM $SCHEMA.s12_items) / coalesce(last_value, start_value) > 100 FROM pg_sequences WHERE sequencename = 's12_items_id_seq'")"
assert_true "the next default id collides with loaded data" "$([[ "$err" == *"duplicate key value"* ]] && echo t || echo f)"
assert_true "the sequence is behind the data" "$(val "SELECT coalesce(last_value, start_value - 1) < (SELECT max(id) FROM $SCHEMA.s12_items) FROM pg_sequences WHERE sequencename = 's12_items_id_seq'")"
assert_true "max(id) is read through the primary key index, not a sequential scan" "$( psql -X -At -c "EXPLAIN (COSTS OFF) SELECT max(id) FROM $SCHEMA.s12_items" | grep -qi 'index' && echo t || echo f)"
say "expected finding"
note "s12_items.id: the sequence is behind the data, so the next insert fails now. Not a projection and not a"
note "percentage: a state, with the fix to run by hand: SELECT setval('s12_items_id_seq', max(id)) FROM ..."
