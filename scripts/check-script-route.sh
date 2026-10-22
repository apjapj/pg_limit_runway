#!/usr/bin/env bash
# scripts/check-script-route.sh: the alternative install route on one server.
#
# Throwaway database: install, marker and writer; install again must refuse; uninstall leaves no
# object; reinstall and migrate is a no-op. Needs createdb/dropdb rights.
set -euo pipefail

db="lr_script_route_check_$$"
cleanup() { dropdb --if-exists "$db" >/dev/null 2>&1 || true; }
trap cleanup EXIT

createdb "$db"
export PGDATABASE="$db"

psql -X -q -v ON_ERROR_STOP=1 -f scripts/sql/install.sql
psql -X -q -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM limit_runway;" >/dev/null
test "$(psql -X -At -c "SELECT version FROM limit_runway_script_install")" = "0.7.0"
psql -X -q -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM limit_runway_sample();" >/dev/null

if psql -X -q -v ON_ERROR_STOP=1 -f scripts/sql/install.sql >/dev/null 2>&1; then
    echo "FAIL: install succeeded twice" >&2
    exit 1
fi
if psql -X -q -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_limit_runway" >/dev/null 2>&1; then
    echo "FAIL: CREATE EXTENSION succeeded while the script route is installed" >&2
    exit 1
fi

psql -X -q -v ON_ERROR_STOP=1 -f scripts/sql/uninstall.sql
test -z "$(psql -X -At -c "SELECT to_regclass('limit_runway')::text || to_regclass('limit_runway_history')::text || to_regclass('limit_runway_script_install')::text")"

psql -X -q -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_limit_runway"
if psql -X -q -v ON_ERROR_STOP=1 -f scripts/sql/install.sql >/dev/null 2>&1; then
    echo "FAIL: script install succeeded on an extension install" >&2
    exit 1
fi
psql -X -q -v ON_ERROR_STOP=1 -c "DROP EXTENSION pg_limit_runway"

psql -X -q -v ON_ERROR_STOP=1 -f scripts/sql/install.sql
psql -X -q -v ON_ERROR_STOP=1 -f scripts/sql/migrate.sql
test "$(psql -X -At -c "SELECT version FROM limit_runway_script_install")" = "0.7.0"
# The release script closes the readers; the script route must not open them.
test "$(psql -X -At -c "SELECT has_function_privilege('public', 'limit_runway_findings(numeric,interval)', 'EXECUTE')")" = "f"
test "$(psql -X -At -c "SELECT has_function_privilege('public', 'limit_runway_rate(text,text)', 'EXECUTE')")" = "f"
echo "PASS: script route install, both refusals, grants, uninstall and no-op migration"
