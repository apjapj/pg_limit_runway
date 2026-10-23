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
# The order rules live once, in internal-tooling, vendored as scripts/order-rules.sh. val() uses the exact
# rule, where the row count is known; check-examples.sh uses the plan rule.
. "$HERE/../scripts/order-rules.sh"

psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
# The exact nondeterministic-order rule, where the row count is known: a statement that returned
# more than one row and has no ORDER BY, judged by order-rules.sh. The warning goes to a side file,
# never to stdout or stderr, because run.sh captures both into the evidence. run.sh reads the file.
val() {
    local sql=$1 out
    out=$(psql -X -At -v ON_ERROR_STOP=1 -c "$sql")
    [ -n "$(order_val_multirow "$sql" "$out")" ] && \
        printf '%s\t%s\n' "${LR_SCENARIO:-?}" "$(printf '%s' "$sql" | tr '\n\t' '  ' | cut -c1-120)" \
            >> "$RUNDIR/order-warnings"
    printf '%s\n' "$out"
}
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

# ---------------------------------------------------------------- the extension's own finding
#
# When pg_limit_runway is available on the server, scenarios also check what the extension says against
# the finding docs/ranking.md predicts. A "FAIL" line makes run.sh report the scenario as FAILED.
has_extension() {
    [ "$(val "SELECT count(*) FROM pg_available_extensions WHERE name = 'pg_limit_runway'")" = 1 ]
}
use_extension() {
    has_extension || return 1
    psql_q -c "CREATE EXTENSION IF NOT EXISTS pg_limit_runway" 2>/dev/null
}
# $1 a LIKE pattern on the object: prints the sentence form of every matching finding.
finding() {
    use_extension || { note "pg_limit_runway is not installed on this server; finding not checked"; return 0; }
    say "what pg_limit_runway says"
    local line
    while IFS= read -r line; do note "$line"; done < <(val "SELECT t FROM limit_runway_text() t WHERE t LIKE '% $1: %'")
}
# $1 object (exact), $2 expected state ('none' for no row), $3 a LIKE pattern the "then" lines must
# match (or ''), $4 a LIKE pattern the unknowns must match ('' means none), $5 a LIKE pattern for the
# detail (or ''), $6 the expected rank_class (or ''). Run as LR_ROLE when set, through SET ROLE.
assert_finding() {
    use_extension || return 0
    local o=$1 want=$2 thenp=${3:-} unkp=${4:-} detp=${5:-} cls=${6:-} got bad=""
    got=$(psql -X -At -q -v ON_ERROR_STOP=1 -c "${LR_ROLE:+SET ROLE $LR_ROLE; }SELECT state || '|' || rank_class || '|' || detail || '|'
                      || array_to_string(\"then\", ' ;; ') || '|' || array_to_string(unknowns, ' ;; ')
                 FROM limit_runway_findings() WHERE object = '$o'")
    local state=${got%%|*} rest=${got#*|}
    local rc=${rest%%|*}; rest=${rest#*|}
    local detail=${rest%%|*}; rest=${rest#*|}
    local thens=${rest%%|*} unks=${rest#*|}
    like() { [ "$(val "SELECT \$q\$$1\$q\$ LIKE \$q\$$2\$q\$")" = t ]; }
    if [ -z "$got" ]; then
        [ "$want" = none ] || bad="$bad; no row, expected '$want'"
    elif [ "$want" = none ]; then bad="$bad; expected no row, got '$state'"
    else
        [ "$state" != "$want" ] && bad="$bad; state is '$state', expected '$want'"
        [ -n "$cls" ] && [ "$rc" != "$cls" ] && bad="$bad; rank_class is $rc, expected $cls"
        [ -n "$detp" ] && ! like "$detail" "$detp" && bad="$bad; detail does not match '$detp'"
        [ -n "$thenp" ] && ! like "$thens" "$thenp" && bad="$bad; then does not match '$thenp'"
        if [ -z "$unkp" ]; then [ -n "$unks" ] && bad="$bad; unknowns not empty: $unks"
        else like "$unks" "$unkp" || bad="$bad; unknowns do not match '$unkp'"; fi
    fi
    if [ -z "$bad" ]; then note "PASS  finding for $o: $want${cls:+ (class $cls)}${thenp:+, then $thenp}${unkp:+, unknowns $unkp}"
    else note "FAIL  finding for $o${bad}"; fi
}
# $1 before $2 in the view's order.
assert_ranked_before() {
    use_extension || return 0
    assert_true "the view lists $1 before $2" "$(val "WITH v AS (SELECT object, row_number() OVER () AS n FROM limit_runway)
        SELECT (SELECT n FROM v WHERE object = '$1') < (SELECT n FROM v WHERE object = '$2')")"
}

# ---------------------------------------------------------------- history (0.2)
#
# Samples laid down at chosen instants, relative to one BASE taken once per scenario, so every rate and
# every date is exact arithmetic on the fixture rather than on how long the script took to run. The
# sequences are moved for real (inserts, nextval, setval) between samples. $1 an interval before BASE
# ('2 days'), or '0' for BASE itself; prints how many limits were sampled.
take_base() { BASE=$(val "SELECT now()::text"); }
sample_at() {
    val "SELECT sum(sampled) FROM limit_runway_sample('$BASE'::timestamptz - interval '$1')"
}
