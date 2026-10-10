#!/usr/bin/env bash
# s11: two limits at once, to pin down the ordering docs/ranking.md decides.
#   s11_tickets.id (int2 identity) with 7 values left: close, but nothing is failing yet.
#   s11_audit, range-partitioned by time, whose last partition ended 2026-02-01: every insert for today
#   already fails.
. "$(dirname "$0")/lib.sh"
setup_schema
psql_q -c "CREATE TABLE $SCHEMA.s11_tickets (id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, x int)" \
       -c "INSERT INTO $SCHEMA.s11_tickets (x) SELECT g FROM generate_series(1, 32760) g" \
       -c "CREATE TABLE $SCHEMA.s11_audit (at timestamptz NOT NULL, v int) PARTITION BY RANGE (at)" \
       -c "CREATE TABLE $SCHEMA.s11_audit_2026_01 PARTITION OF $SCHEMA.s11_audit FOR VALUES FROM ('2026-01-01') TO ('2026-02-01')" >/dev/null

say "what actually happens, now"
et=$(try_sql "INSERT INTO $SCHEMA.s11_tickets (x) VALUES (0)")
note "an insert into s11_tickets: ${et:-succeeds}"
ea=$(try_sql "INSERT INTO $SCHEMA.s11_audit VALUES (now(), 0)")
note "an insert into s11_audit for now(): ${ea:-succeeds}"
note "s11_tickets has $(val "SELECT max_value - last_value FROM pg_sequences WHERE sequencename LIKE 's11_tickets%'") values left of $(val "SELECT max_value FROM pg_sequences WHERE sequencename LIKE 's11_tickets%'")"

say "checks"
assert_true "s11_tickets still accepts inserts" "$([ -z "$et" ] && echo t || echo f)"
assert_true "s11_tickets has 6 values left after that insert" "$(val "SELECT max_value - last_value = 6 FROM pg_sequences WHERE sequencename LIKE 's11_tickets%'")"
assert_true "s11_audit already refuses every insert for the present" "$([[ "$ea" == *"no partition of relation"* ]] && echo t || echo f)"
say "expected finding"
note "First s11_audit: already reached, failing now. Then s11_tickets: 6 values left, no rate yet, so no"
note "date. A limit that is failing now outranks one that is merely close, however close."
