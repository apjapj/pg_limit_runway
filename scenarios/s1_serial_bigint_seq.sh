#!/usr/bin/env bash
# s1: a 9.x-era serial. Before PostgreSQL 10 a sequence was always bigint, so a `serial` (int4) column
# from that era is fed by a bigint sequence. The limit is the COLUMN's, 2,147,483,647, not the
# sequence's 9.2e18, and only pg_depend ties the sequence to its column. Built here as it would have
# been restored from an old dump: a bigint sequence, an int4 column, OWNED BY.
. "$(dirname "$0")/lib.sh"
setup_schema
psql_q -c "CREATE SEQUENCE $SCHEMA.s1_orders_id_seq AS bigint" \
       -c "CREATE TABLE $SCHEMA.s1_orders (id int4 PRIMARY KEY DEFAULT nextval('$SCHEMA.s1_orders_id_seq'), note text)" \
       -c "ALTER SEQUENCE $SCHEMA.s1_orders_id_seq OWNED BY $SCHEMA.s1_orders.id" \
       -c "SELECT setval('$SCHEMA.s1_orders_id_seq', 2147483640)" \
       -c "INSERT INTO $SCHEMA.s1_orders (note) SELECT 'row' FROM generate_series(1, 7)" >/dev/null

say "the usual check (pg_sequences, last_value against max_value)"
psql -X -P pager=off -c "
SELECT sequencename, data_type, last_value, max_value, round(100.0 * last_value / max_value, 6) AS pct_used
  FROM pg_sequences WHERE schemaname = '$SCHEMA' AND sequencename = 's1_orders_id_seq'"

say "what actually happens: the next insert"
err=$(try_sql "INSERT INTO $SCHEMA.s1_orders (note) VALUES ('one more')")
note "${err:-(no error)}"

say "evidence: the column the sequence feeds, through pg_depend"
psql -X -P pager=off -c "
SELECT s.relname AS sequence, c.relname AS tbl, a.attname AS col, format_type(a.atttypid, a.atttypmod) AS col_type,
       sq.seqtypid::regtype AS seq_type, (SELECT last_value FROM $SCHEMA.s1_orders_id_seq) AS last_value,
       2147483647 - (SELECT last_value FROM $SCHEMA.s1_orders_id_seq) AS left_before_column_overflows
  FROM pg_depend d
  JOIN pg_class s ON s.oid = d.objid AND s.relkind = 'S'
  JOIN pg_sequence sq ON sq.seqrelid = s.oid
  JOIN pg_class c ON c.oid = d.refobjid
  JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = d.refobjsubid
 WHERE s.relname = 's1_orders_id_seq' AND d.deptype IN ('a', 'i')"

say "checks"
assert_true "the usual check reports under 0.001% used" "$(val "SELECT 100.0 * last_value / max_value < 0.001 FROM pg_sequences WHERE sequencename = 's1_orders_id_seq'")"
assert_true "the next insert fails with integer out of range" "$([[ "$err" == *"integer out of range"* ]] && echo t || echo f)"
assert_true "the failed insert still consumed a value: the sequence is past the column's maximum" "$(val "SELECT last_value > 2147483647 FROM pg_sequences WHERE sequencename = 's1_orders_id_seq'")"
finding "lr_scen.s1_orders.id"
assert_finding lr_scen.s1_orders.id exhausted '' '' '%stands past it at 2147483648%' 1
say "expected finding"
note "s1_orders.id (int4) is exhausted. The limit is the column's 2147483647, found through pg_depend, not"
note "the bigint sequence's. And the failed insert still consumed a value, so the sequence now stands PAST"
note "the column's maximum (2147483648) and 'values left' computes to -1: report exhausted, not a count."
