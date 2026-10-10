#!/usr/bin/env bash
# s10: connection headroom. The usual check compares a count of pg_stat_activity with max_connections.
# A role or a database can run out long before that: rolconnlimit and datconnlimit are limits of their
# own. And not all of max_connections is for ordinary roles: superuser_reserved_connections, and from 16
# reserved_connections, are held back. And neither per-role nor per-database limits apply to a superuser,
# which the first draft found by testing the database limit as one: a monitoring tool connected as a
# superuser is not bound by the limits the application runs into.
. "$(dirname "$0")/lib.sh"
psql_q -c "CREATE ROLE lr_scen_app LOGIN PASSWORD 'test' CONNECTION LIMIT 2" \
       -c "CREATE ROLE lr_scen_web LOGIN PASSWORD 'test'" \
       -c "CREATE DATABASE lr_scen_db CONNECTION LIMIT 1" >/dev/null
export PGPASSWORD=test
start_session app1 "SELECT 1;" "-U lr_scen_app"
start_session app2 "SELECT 1;" "-U lr_scen_app"
start_session db1  "SELECT 1;" "-U lr_scen_web -d lr_scen_db"
wait_for "(SELECT count(*) = 2 FROM pg_stat_activity WHERE usename = 'lr_scen_app') AND (SELECT count(*) = 1 FROM pg_stat_activity WHERE datname = 'lr_scen_db')" 20 "the three sessions"

say "the usual check: sessions against max_connections"
psql -X -P pager=off -c "SELECT count(*) < current_setting('max_connections')::int / 2 AS plenty_of_headroom,
                                current_setting('max_connections')::int AS max_connections FROM pg_stat_activity"

say "what actually happens"
er=$(PGUSER=lr_scen_app psql -X -At -c "SELECT 1" 2>&1 | grep -oE 'FATAL: +.*' | head -1)
note "a third session for lr_scen_app: $er"
ed=$(PGUSER=lr_scen_web psql -X -At -d lr_scen_db -c "SELECT 1" 2>&1 | grep -oE 'FATAL: +.*' | head -1)
note "a second session in lr_scen_db, as lr_scen_web: $ed"
es=$(psql -X -At -d lr_scen_db -c "SELECT 'superuser let in'" 2>&1 | head -1)
note "the same, as the superuser postgres: $es"

say "evidence: the limits a tool would read"
if [ "$VER" -ge 160000 ]; then reserved="current_setting('reserved_connections')::int"; else reserved="NULL::int"; fi
psql -X -P pager=off -c "
SELECT current_setting('max_connections')::int AS max_connections,
       current_setting('superuser_reserved_connections')::int AS superuser_reserved,
       $reserved AS reserved_connections,
       current_setting('max_connections')::int - current_setting('superuser_reserved_connections')::int
         - coalesce($reserved, 0) AS for_ordinary_roles"
psql -X -P pager=off -c "
SELECT 'role' AS kind, rolname AS name, rolconnlimit AS lim,
       (SELECT count(*) FROM pg_stat_activity WHERE usename = rolname) AS used FROM pg_roles WHERE rolname = 'lr_scen_app'
UNION ALL
SELECT 'database', datname, datconnlimit, (SELECT count(*) FROM pg_stat_activity a WHERE a.datname = d.datname)
  FROM pg_database d WHERE datname = 'lr_scen_db'"
[ "$VER" -ge 160000 ] || note "reserved_connections does not exist before 16: on this version only superuser_reserved_connections is held back"

say "checks"
assert_true "the usual check says there is plenty of headroom" "$(val "SELECT count(*) < current_setting('max_connections')::int / 2 FROM pg_stat_activity")"
assert_true "and the role is out: a third session is refused" "$([[ "$er" == *"too many connections for role"* ]] && echo t || echo f)"
assert_true "and the database is out: a second ordinary session is refused" "$([[ "$ed" == *"too many connections for database"* ]] && echo t || echo f)"
assert_true "but a superuser is let in past the database's limit" "$([ "$es" = "superuser let in" ] && echo t || echo f)"
finding "% lr_scen_%"
assert_finding 'role lr_scen_app' full '%superusers are exempt%' '' '2 of 2 connections%' 1
assert_finding 'database lr_scen_db' full '%superusers are exempt%' '' '1 of 1 connections%' 1
assert_finding 'role lr_scen_web' none
say "expected finding"
note "lr_scen_app: 2 of 2 connections in use; lr_scen_db: 1 of 1. Both full while the server has headroom."
note "Headroom is a peak against a limit, not a rate: report the highest use over the window, per role and"
note "per database as well as for the server. Superusers are exempt from the per-role and per-database"
note "limits, so a check run as one cannot test them by trying to connect."
