#!/usr/bin/env bash
# bench-overhead.sh: what one call to the read side costs, beside a hand-written baseline.
#
# Why this exists. The optional overhead tile needs a number with a fixture under it. This states
# the fixture, takes the median of N calls, and prints the same measurement for the hand-written
# query an operator would otherwise paste, so the cost of the extension is visible rather than
# asserted.
#
# What is measured. `SELECT count(*) FROM limit_runway_text()` and
# `... limit_runway_findings()`, run from psql with `\timing on`. That is parse, plan, execute and
# the round trip: a function has no plan cache across separate statements, so this is what a person
# running the command in psql pays. The count(*) keeps the rows the client transfers constant. The
# median is the warm steady state; the first call in a fresh backend pays for cold catalog caches.
#
# The baseline is the hand-written pg_sequences query that answers "which sequences are past half
# their range" without a rate, a column type, or a date: a smaller question, so it is a floor.
#
# The fixture. N sequences with MAXVALUE 1000, started at 900 and advanced once, so each is 90% used
# and each is a finding at the default min_used of 0.5. It creates and drops its own sequences, by a
# name prefix, and nothing else.
#
# Usage:
#   ./scripts/bench-overhead.sh                     # 10 sequences, median of 30
#   ./scripts/bench-overhead.sh --sequences=50 --repeat=10
#   ./scripts/bench-overhead.sh --keep              # leave the fixture sequences behind
#   ./scripts/bench-overhead.sh --force             # required: it creates and drops objects
#
# Needs superuser: it creates sequences in the current schema.
set -uo pipefail
cd "$(dirname "$0")/.."

: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGUSER PGDATABASE

sequences=10
repeat=30
keep=0
force=0
prefix=runway_bench_fixture

while [ "$#" -gt 0 ]; do
    case "$1" in
        --sequences=*) sequences="${1#*=}" ;;
        --repeat=*)    repeat="${1#*=}" ;;
        --keep)        keep=1 ;;
        --force)       force=1 ;;
        -h|--help)     sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$force" -ne 1 ]; then
    cat >&2 <<'MSG'
  This script creates N sequences and advances them, then drops them, in the database named by
  PGDATABASE. Run it against a scratch database, or pass --force to confirm.
MSG
    exit 2
fi

q() { psql -X -tA -c "$1" 2>/dev/null; }

if [ "$(q "SELECT count(*) FROM pg_extension WHERE extname='pg_limit_runway'")" != 1 ]; then
    echo "  pg_limit_runway is not installed in $PGDATABASE on $PGHOST:$PGPORT" >&2
    exit 1
fi

version=$(q "SELECT current_setting('server_version')")
printf '\n  \033[1mpg_limit_runway read-overhead benchmark\033[0m\n'
printf '  server %s on %s, database %s, median of %s calls\n' "$version" "$PGHOST" "$PGDATABASE" "$repeat"
printf '  fixture: %s sequences, MAXVALUE 1000, started at 900 and advanced once (90%% used)\n\n' "$sequences"

psql -X -q >/dev/null 2>&1 <<SQL
DO \$do\$
DECLARE i int;
BEGIN
  FOR i IN 1..$sequences LOOP
    EXECUTE format('DROP SEQUENCE IF EXISTS ${prefix}_%s', i);
    EXECUTE format('CREATE SEQUENCE ${prefix}_%s MAXVALUE 1000 START WITH 900', i);
    PERFORM nextval(format('${prefix}_%s', i));
  END LOOP;
END
\$do\$;
SQL

seen=$(q "SELECT count(*) FROM limit_runway_findings() WHERE kind = 'sequence' AND object LIKE '%.${prefix}_%' AND used_fraction >= 0.5")
if [ "${seen:-0}" -ne "$sequences" ]; then
    # A benchmark that does not check its own fixture is how a quiet cluster gets timed and called a
    # result. Every fixture sequence must be a finding before anything is timed.
    printf '  fixture wrong: limit_runway_findings() returned %s of %s fixture sequences as findings; refusing to time\n' \
           "${seen:-?}" "$sequences" >&2
    for i in $(seq 1 "$sequences"); do q "DROP SEQUENCE IF EXISTS ${prefix}_$i" >/dev/null; done
    exit 1
fi

median_ms() {
    sort -n | awk '
        { a[NR] = $1 }
        END {
            if (NR == 0) { print "?"; exit }
            if (NR % 2) { printf "%.2f", a[(NR+1)/2] }
            else        { printf "%.2f", (a[NR/2] + a[NR/2+1]) / 2 }
        }'
}

time_sql() {
    sql=${1%;}
    tmp=$(mktemp)
    { echo '\timing on'; for _ in $(seq 1 "$repeat"); do printf '%s;\n' "$sql"; done; } \
        | psql -X -A -t 2>/dev/null \
        | grep '^Time:' | sed 's/^Time: //; s/ ms$//' > "$tmp"
    # A missing semicolon once made psql read every call as one statement and print one Time line,
    # so a "median of 30" was a median of one sample. Count the samples and refuse a short one.
    n=$(wc -l < "$tmp")
    if [ "$n" -ne "$repeat" ]; then
        printf '  expected %s timings, got %s; refusing to report a median from them\n' "$repeat" "$n" >&2
        rm -f "$tmp"
        return 1
    fi
    median_ms < "$tmp"
    rm -f "$tmp"
}

printf '  %-30s %-28s %s\n' 'limit_runway_text()' 'limit_runway_findings()' 'baseline: pg_sequences'
printf '  %s\n' '-------------------------------------------------------------------------------------'

if ! text=$(time_sql "SELECT count(*) FROM limit_runway_text()") \
   || ! find=$(time_sql "SELECT count(*) FROM limit_runway_findings()") \
   || ! base=$(time_sql "SELECT count(*) FROM pg_sequences WHERE last_value IS NOT NULL AND last_value::numeric / max_value::numeric >= 0.5"); then
    for i in $(seq 1 "$sequences"); do q "DROP SEQUENCE IF EXISTS ${prefix}_$i" >/dev/null; done
    exit 1
fi
printf '  %-30s %-28s %s\n' "$text" "$find" "$base"

if [ "$keep" -eq 0 ]; then
    for i in $(seq 1 "$sequences"); do q "DROP SEQUENCE IF EXISTS ${prefix}_$i" >/dev/null; done
fi
printf '\n  all times in milliseconds. The baseline answers a smaller question; see the header.\n\n'
