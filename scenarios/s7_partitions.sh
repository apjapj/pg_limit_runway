#!/usr/bin/env bash
# s7: time-range partitions. Fixed dates, so the evidence does not move with the calendar.
#   s7_events:        last partition ends 2026-03-01, no DEFAULT: an insert past it fails.
#   s7_events_dflt:   the same with a DEFAULT: the insert succeeds, silently, into the default, and then
#                     the partition that should hold it can no longer be created.
#   s7_accounts:      range-partitioned on an integer: not a time key, must be skipped, not misread.
. "$(dirname "$0")/lib.sh"
setup_schema
psql_q -c "CREATE TABLE $SCHEMA.s7_events (at timestamptz NOT NULL, v int) PARTITION BY RANGE (at)" \
       -c "CREATE TABLE $SCHEMA.s7_events_2026_01 PARTITION OF $SCHEMA.s7_events FOR VALUES FROM ('2026-01-01') TO ('2026-02-01')" \
       -c "CREATE TABLE $SCHEMA.s7_events_2026_02 PARTITION OF $SCHEMA.s7_events FOR VALUES FROM ('2026-02-01') TO ('2026-03-01')" \
       -c "CREATE TABLE $SCHEMA.s7_events_dflt (at timestamptz NOT NULL, v int) PARTITION BY RANGE (at)" \
       -c "CREATE TABLE $SCHEMA.s7_events_dflt_2026_02 PARTITION OF $SCHEMA.s7_events_dflt FOR VALUES FROM ('2026-02-01') TO ('2026-03-01')" \
       -c "CREATE TABLE $SCHEMA.s7_events_dflt_default PARTITION OF $SCHEMA.s7_events_dflt DEFAULT" \
       -c "CREATE TABLE $SCHEMA.s7_accounts (account_id int NOT NULL) PARTITION BY RANGE (account_id)" \
       -c "CREATE TABLE $SCHEMA.s7_accounts_0 PARTITION OF $SCHEMA.s7_accounts FOR VALUES FROM (0) TO (1000000)" >/dev/null

say "the usual check: list the partitions and their bounds"
psql -X -P pager=off -c "
SELECT i.inhparent::regclass AS parent, c.relname AS partition, pg_get_expr(c.relpartbound, c.oid) AS bound
  FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
 WHERE c.relnamespace = '$SCHEMA'::regnamespace ORDER BY 1, 2"

say "what actually happens: a row for 2026-03-15"
e1=$(try_sql "INSERT INTO $SCHEMA.s7_events VALUES ('2026-03-15', 1)")
note "without a DEFAULT: ${e1:-(no error)}"
e2=$(try_sql "INSERT INTO $SCHEMA.s7_events_dflt VALUES ('2026-03-15', 1)")
note "with a DEFAULT: ${e2:-(no error)}, and the default now holds $(val "SELECT count(*) FROM $SCHEMA.s7_events_dflt_default") row(s)"
e3=$(try_sql "CREATE TABLE $SCHEMA.s7_events_dflt_2026_03 PARTITION OF $SCHEMA.s7_events_dflt FOR VALUES FROM ('2026-03-01') TO ('2026-04-01')")
note "then creating the March partition: ${e3:-(no error)}"

say "evidence: the partition key's type and the last upper bound"
psql -X -P pager=off -c "
SELECT p.partrelid::regclass AS parent, p.partstrat, format_type(a.atttypid, a.atttypmod) AS key_type,
       a.atttypid IN ('timestamptz'::regtype, 'timestamp'::regtype, 'date'::regtype) AS time_key,
       EXISTS (SELECT 1 FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
                WHERE i.inhparent = p.partrelid AND pg_get_expr(c.relpartbound, c.oid) = 'DEFAULT') AS has_default
  FROM pg_partitioned_table p JOIN pg_attribute a ON a.attrelid = p.partrelid AND a.attnum = p.partattrs[0]
 WHERE p.partrelid::regclass::text LIKE '$SCHEMA.%' ORDER BY 1"

say "checks"
assert_true "without a DEFAULT, the insert past the last bound fails" "$([[ "$e1" == *"no partition of relation"* ]] && echo t || echo f)"
assert_true "with a DEFAULT, the same insert succeeds, into the default" "$([ -z "$e2" ] && [ "$(val "SELECT count(*) FROM $SCHEMA.s7_events_dflt_default")" = 1 ] && echo t || echo f)"
assert_true "and the partition for that range can then no longer be created" "$([[ "$e3" == *"would be violated"* ]] && echo t || echo f)"
assert_true "s7_accounts is partitioned on a non-time key" "$(val "SELECT NOT (a.atttypid IN ('timestamptz'::regtype, 'timestamp'::regtype, 'date'::regtype)) FROM pg_partitioned_table p JOIN pg_attribute a ON a.attrelid = p.partrelid AND a.attnum = p.partattrs[0] WHERE p.partrelid = '$SCHEMA.s7_accounts'::regclass")"
say "expected finding"
note "s7_events: runs out at 2026-03-01, a fixed boundary with no rate. s7_events_dflt: has 'run out' into its"
note "DEFAULT, which hides it, and that row now blocks creating the missing partition: a worse finding, not a"
note "safer one. s7_accounts: skipped, its key is not a time."
