#!/usr/bin/env bash
# s8: an inactive physical slot. Two different limits depending on max_slot_wal_keep_size:
#   unset (-1, the default): the slot keeps WAL forever. Nothing invalidates it; the risk is the DISK.
#   set:                     WAL past that size is released and the slot is invalidated ("lost").
. "$(dirname "$0")/lib.sh"
setup_schema
psql_q -c "SELECT pg_create_physical_replication_slot('lr_scen_slot', true)" \
       -c "CREATE TABLE $SCHEMA.s8_churn (id serial, v text)" >/dev/null
churn() {   # $1 segments' worth of WAL
    local i; for i in $(seq 1 "$1"); do
        psql_q -c "INSERT INTO $SCHEMA.s8_churn (v) SELECT repeat('x', 200) FROM generate_series(1, 60000)" -c "SELECT pg_switch_wal()" >/dev/null
    done
}
slot() { val "SELECT wal_status || ', safe_wal_size ' || CASE WHEN safe_wal_size IS NULL THEN 'NULL' WHEN safe_wal_size < 0 THEN 'negative' ELSE 'positive' END FROM pg_replication_slots WHERE slot_name = 'lr_scen_slot'"; }

say "part 1: max_slot_wal_keep_size unset ($(val "SHOW max_slot_wal_keep_size"))"
churn 4; psql_q -c "CHECKPOINT"
note "after 4 segments of WAL and a checkpoint: $(slot)"
assert_true "unset, the slot is not threatened with invalidation: wal_status is reserved, safe_wal_size NULL" "$(val "SELECT wal_status = 'reserved' AND safe_wal_size IS NULL FROM pg_replication_slots WHERE slot_name = 'lr_scen_slot'")"
assert_true "and it holds WAL back: its restart_lsn is 4 segments or more behind" "$(val "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) >= 4 * 16 * 1024 * 1024 FROM pg_replication_slots WHERE slot_name = 'lr_scen_slot'")"

say "part 2: max_slot_wal_keep_size = 32MB"
psql_q -c "ALTER SYSTEM SET max_slot_wal_keep_size = '32MB'" -c "SELECT pg_reload_conf()" >/dev/null
wait_for "current_setting('max_slot_wal_keep_size') = '32MB'" 10 "the reload"
note "set: $(slot)"
for _ in 1 2 3 4 5 6; do
    [ "$(val "SELECT wal_status FROM pg_replication_slots WHERE slot_name = 'lr_scen_slot'")" = lost ] && break
    churn 2; psql_q -c "CHECKPOINT"
done
note "after more WAL and checkpoints: $(slot)"
assert_true "set, the slot is invalidated: wal_status lost" "$(val "SELECT wal_status = 'lost' FROM pg_replication_slots WHERE slot_name = 'lr_scen_slot'")"
psql_q -c "ALTER SYSTEM RESET max_slot_wal_keep_size" -c "SELECT pg_reload_conf()" >/dev/null
say "expected finding"
note "unset: the slot's limit is the disk holding pg_wal, a different limit with no invalidation, and"
note "safe_wal_size is NULL. Set: the limit is safe_wal_size counting down to invalidation, then 'lost'."
