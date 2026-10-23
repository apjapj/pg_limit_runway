#!/usr/bin/env bash
# s9: passwords with VALID UNTIL. Four roles: expired yesterday, expiring in 3 days, 'infinity', none.
# The README's open item: does an expired role actually lose access? Over a password login, yes. Over a
# login that uses no password (the server's local socket, which trusts), VALID UNTIL is never
# consulted. That second half is tested two ways, because the two CI platforms reach the socket
# differently: LR_CONTAINER names a sibling container to docker exec into, which is how ci/job.sh
# runs it, and a direct socket connection covers the Forgejo runner, where the server is inside the
# job container and there is no sibling to exec into. Both must print the SAME sentence, or the one
# committed evidence file per version cannot match on both platforms.
. "$(dirname "$0")/lib.sh"
psql_q -c "CREATE ROLE lr_scen_expired LOGIN PASSWORD 'test' VALID UNTIL '$(val "SELECT now() - interval '1 day'")'" \
       -c "CREATE ROLE lr_scen_soon    LOGIN PASSWORD 'test' VALID UNTIL '$(val "SELECT now() + interval '3 days'")'" \
       -c "CREATE ROLE lr_scen_forever LOGIN PASSWORD 'test' VALID UNTIL 'infinity'" \
       -c "CREATE ROLE lr_scen_none    LOGIN PASSWORD 'test'" >/dev/null

say "the usual check: pg_roles.rolvaliduntil, which any role can read"
psql -X -P pager=off -c "
SELECT rolname, CASE WHEN rolvaliduntil IS NULL THEN 'NULL' WHEN rolvaliduntil = 'infinity' THEN 'infinity'
                     ELSE round(extract(epoch FROM rolvaliduntil - now()) / 86400)::text || ' days' END AS valid_for
  FROM pg_roles WHERE rolname LIKE 'lr_scen_%' ORDER BY 1"

say "what actually happens: a password login as each role"
for r in expired soon forever none; do
    e=$(PGUSER=lr_scen_$r PGPASSWORD=test psql -X -At -c "SELECT 'logged in'" 2>&1 | sed 's/^psql: error: [^:]*: //;s/connection to server at "[^"]*" ([^)]*), port [0-9]* failed: //' | head -1)
    note "lr_scen_$r: $e"
done
ex=$(PGUSER=lr_scen_expired PGPASSWORD=test psql -X -At -c "SELECT 1" 2>&1 | head -1)
# $PGPORT, not a literal 5432: on a host running the internal-tooling compose stack there IS a socket at
# the same path for port 5432, belonging to a different server. Checking the bare path would let this
# silently test the wrong server and report a pass for a question it never asked.
sock_tested=0
if [ -n "${LR_CONTAINER:-}" ]; then
    sock=$(docker exec "$LR_CONTAINER" psql -X -At -U lr_scen_expired -d postgres -c "SELECT 'logged in, over the local socket'" 2>&1 | head -1)
    sock_tested=1
else
    sockdir=$(val "SHOW unix_socket_directories" | cut -d, -f1 | tr -d ' ')
    if [ -n "$sockdir" ] && [ -S "$sockdir/.s.PGSQL.$PGPORT" ]; then
        sock=$(psql -h "$sockdir" -X -At -U lr_scen_expired -d postgres -c "SELECT 'logged in, over the local socket'" 2>&1 | head -1)
        sock_tested=1
    fi
fi
if [ "$sock_tested" = 1 ]; then
    note "lr_scen_expired, over the container's local socket (trust): $sock"
else
    sock=""; note "LR_CONTAINER not set: the non-password login is not tested"
fi

say "checks"
assert_true "the expired role is refused over a password login" "$([[ "$ex" == *"password authentication failed"* ]] && echo t || echo f)"
assert_true "the role expiring in 3 days still logs in" "$( [ "$(PGUSER=lr_scen_soon PGPASSWORD=test psql -X -At -c 'SELECT 1' 2>/dev/null)" = 1 ] && echo t || echo f)"
assert_true "infinity and no VALID UNTIL both log in" "$( [ "$(PGUSER=lr_scen_forever PGPASSWORD=test psql -X -At -c 'SELECT 1' 2>/dev/null)$(PGUSER=lr_scen_none PGPASSWORD=test psql -X -At -c 'SELECT 1' 2>/dev/null)" = 11 ] && echo t || echo f)"
[ "$sock_tested" = 1 ] && assert_true "the expired role still logs in where no password is asked for" "$([[ "$sock" == "logged in, over the local socket" ]] && echo t || echo f)"
finding "role lr_scen_%"
assert_finding 'role lr_scen_expired' expired '%do not use a password are not affected%' '' '' 1
assert_finding 'role lr_scen_soon' date '%do not use a password are not affected%' '' '' 2
assert_finding 'role lr_scen_forever' none
assert_finding 'role lr_scen_none' none
say "expected finding"
note "lr_scen_soon: password expires in 3 days, a fixed date with no rate. lr_scen_expired: expired, which"
note "refuses PASSWORD logins only; a role that also connects by trust, peer or certificate keeps working, so"
note "'expired' does not mean 'locked out'. infinity and NULL never expire and are not findings."
