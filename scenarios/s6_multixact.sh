#!/usr/bin/env bash
# s6: MultiXact IDs, made the way real workloads make them: two transactions holding FOR SHARE on the
# same rows. The question the README left open: what can a
# monitoring role without superuser read?
. "$(dirname "$0")/lib.sh"
setup_schema
psql_q -c "CREATE EXTENSION IF NOT EXISTS dblink" \
       -c "CREATE TABLE $SCHEMA.s6_stock (id int PRIMARY KEY, qty int)" \
       -c "INSERT INTO $SCHEMA.s6_stock SELECT g, 0 FROM generate_series(1, 50) g" >/dev/null
before=$(val "SELECT mxid_age(datminmxid) FROM pg_database WHERE datname = current_database()")
psql_q -c "DO \$\$
DECLARE c text := 'dbname=' || current_database() || ' user=' || current_user;   -- the server's own socket
BEGIN
  PERFORM dblink_connect('a', c); PERFORM dblink_connect('b', c);
  FOR i IN 1..100 LOOP
    PERFORM dblink_exec('a', 'BEGIN'); PERFORM dblink_exec('b', 'BEGIN');
    PERFORM * FROM dblink('a', 'SELECT 1 FROM $SCHEMA.s6_stock FOR SHARE') AS t(x int);
    PERFORM * FROM dblink('b', 'SELECT 1 FROM $SCHEMA.s6_stock FOR SHARE') AS t(x int);
    PERFORM dblink_exec('a', 'COMMIT'); PERFORM dblink_exec('b', 'COMMIT');
  END LOOP;
  PERFORM dblink_disconnect('a'); PERFORM dblink_disconnect('b');
END \$\$" >/dev/null
after=$(val "SELECT mxid_age(datminmxid) FROM pg_database WHERE datname = current_database()")

say "multixacts made: 100 rounds of two FOR SHARE lockers on 50 rows"
note "mxid_age(datminmxid) grew by $((after - before))"
# Not one per row. The first draft asserted 100 x 50 = 5000 and measured 100: a backend reuses one
# multixact for every row locked by the same set of transactions, so consumption follows the number of
# distinct locker sets, not the number of rows locked.
assert_true "each round made ONE multixact, shared by all 50 rows: 100 in total" "$([ $((after - before)) -eq 100 ] && echo t || echo f)"

say "what a role WITHOUT superuser can read"
psql_q -c "CREATE ROLE lr_scen_monitor LOGIN PASSWORD 'test'" -c "GRANT pg_monitor TO lr_scen_monitor" >/dev/null
m() { PGUSER=lr_scen_monitor psql -X -At -c "$1" 2>&1 | sed 's/^psql:[^:]*:[0-9]*: //' | head -1; }
note "mxid_age(datminmxid) from pg_database:    $( [ -n "$(m "SELECT mxid_age(datminmxid) FROM pg_database WHERE datname = current_database()")" ] && echo readable)"
note "mxid_age(relminmxid) from pg_class:       $( [ -n "$(m "SELECT mxid_age(relminmxid) FROM pg_class WHERE oid = '$SCHEMA.s6_stock'::regclass")" ] && echo readable)"
note "member space, pg_ls_dir('pg_multixact/members'): $(m "SELECT count(*) FROM pg_ls_dir('pg_multixact/members')")"
note "member space, as superuser:               $(val "SELECT count(*) FROM pg_ls_dir('pg_multixact/members')") member segment file(s)"
assert_true "a pg_monitor role reads the multixact ID age" "$( [ -n "$(m "SELECT mxid_age(datminmxid) FROM pg_database LIMIT 1")" ] && echo t || echo f)"
assert_true "a pg_monitor role cannot list member space: pg_ls_dir is refused" "$( [[ "$(m "SELECT count(*) FROM pg_ls_dir('pg_multixact/members')")" == *"permission denied"* ]] && echo t || echo f)"

say "the thresholds"
psql -X -P pager=off -c "SELECT current_setting('autovacuum_multixact_freeze_max_age')::bigint AS autovacuum_multixact_freeze_max_age,
       current_setting('vacuum_multixact_failsafe_age')::bigint AS vacuum_multixact_failsafe_age"
if use_extension; then
    psql_q -c "GRANT EXECUTE ON FUNCTION limit_runway_findings(numeric, interval), limit_runway_text(numeric, interval) TO lr_scen_monitor" -c "GRANT SELECT ON limit_runway TO lr_scen_monitor"
    say "what pg_limit_runway says about member space, as superuser and as the pg_monitor role"
    assert_finding 'member space' 'not established' '' '%member segment file%' '' 5
    LR_ROLE=lr_scen_monitor assert_finding 'member space' 'not established' '' '%needs superuser, or EXECUTE on pg_ls_dir%' '' 5
fi
say "expected finding"
note "MultiXact IDs are consumed per distinct set of lockers, not per row: 100 rounds over 50 rows made 100."
note "Their age is readable by a pg_monitor role and is reported like XID age. Member space is NOT:"
note "listing pg_multixact/members needs superuser, so for a monitoring role the member-space limit is"
note "'not established', not 'fine'."
