# scenarios/lib.sh: shared helpers for the pg_limit_runway scenario fixtures. Sourced, not run.
#
# Each scenario builds a real limit close to, or past, the point where it breaks, in schema lr_scen,
# and prints three things: what the check people usually run reports, what actually happens (often the
# error itself), and the evidence a tool would have to read. scenarios/teardown.sh removes everything.
# Modelled on pg_bloat_cause's scenarios/, so the two read the same.
#
# Run against a scratch server: s5 burns transaction ids, s8 changes max_slot_wal_keep_size with ALTER
# SYSTEM, s9 and s10 create roles and a database. A superuser is needed.
set -uo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGUSER PGDATABASE

SCHEMA=lr_scen
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNDIR="$HERE/.run/${PGHOST}_${PGPORT:-5432}"
mkdir -p "$RUNDIR"

psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
val()    { psql -X -At -v ON_ERROR_STOP=1 -c "$1"; }
# Run SQL that is EXPECTED to fail, and print the error it gave, so the evidence shows the failure
# itself rather than a claim about it.
try_sql() { psql -X -At -v ON_ERROR_STOP=1 -c "$1" 2>&1 | grep -E '^(ERROR|FATAL|psql: error)' | sed 's/^psql: error: [^:]*: //' | head -1; }

VER=$(val "SHOW server_version_num")
say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }
skip() { printf '\n  SKIP  %s\n' "$1"; exit 3; }

setup_schema() { psql_q -c "CREATE SCHEMA IF NOT EXISTS $SCHEMA"; }

# A claim about what actually happened, checked rather than narrated. A FAIL line makes run.sh report the
# scenario as FAILED. $1 is the claim, $2 a SQL boolean or a shell test result ("t"/"f").
assert_true() {
    if [ "$2" = t ] || [ "$2" = true ]; then note "PASS  $1"; else note "FAIL  $1 (got: $2)"; fi
}

# A session that holds something open until teardown kills it. psql blocks on the shell escape, so the
# server sees an idle session. $1 a name, $2 the SQL to run first, $3 optional extra psql arguments.
start_session() {
    local name=$1 sql=$2 extra=${3:-}
    printf "SET application_name = 'lr_scen_%s';\n%s\n\\\\! sleep 86400\n" "$name" "$sql" \
        | psql -X -q $extra >/dev/null 2>&1 &
    echo $! > "$RUNDIR/session_$name.pid"
}
# Wait for a condition instead of sleeping for a guess. $1 a SQL boolean, $2 seconds, $3 what it is.
wait_for() {
    local i
    for i in $(seq 1 $(( ${2:-30} * 5 ))); do
        [ "$(val "SELECT ($1)::text")" = true ] && return 0
        sleep 0.2
    done
    note "FAIL  timed out after ${2:-30} s waiting for: $3"
    return 1
}
