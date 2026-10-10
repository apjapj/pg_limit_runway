#!/usr/bin/env bash
# Remove everything the scenarios left: sessions, roles, the database, the slot, the server setting, the schema.
. "$(dirname "$0")/lib.sh"
for f in "$RUNDIR"/session_*.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f"); pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; rm -f "$f"
done
val "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE application_name LIKE 'lr_scen_%' OR usename LIKE 'lr_scen_%' OR datname = 'lr_scen_db'" >/dev/null
val "SELECT count(pg_drop_replication_slot(slot_name)) FROM pg_replication_slots WHERE slot_name LIKE 'lr_scen_%' AND NOT active" >/dev/null
psql_q -c "ALTER SYSTEM RESET max_slot_wal_keep_size" -c "SELECT pg_reload_conf()" >/dev/null
psql_q -c "DROP DATABASE IF EXISTS lr_scen_db" 2>/dev/null
psql_q -c "DROP SCHEMA IF EXISTS $SCHEMA CASCADE" 2>/dev/null
for r in $(val "SELECT rolname FROM pg_roles WHERE rolname LIKE 'lr_scen_%'"); do psql_q -c "DROP OWNED BY $r" -c "DROP ROLE IF EXISTS $r" 2>/dev/null; done
echo "  teardown done"
