#!/usr/bin/env bash
# scripts/check-script-route-inventory.sh: both routes create the same objects.
#
# Uses ProbeKit v0.1.0. The extension install and the script install are compared by object class
# and identity. The marker table (and its columns) is the one deliberate difference; extension
# membership/config-dump rows are route metadata, not objects.
#
# Runs only where ProbeKit is installed. In the Forgejo CI the check clones/installs the tag first.
set -euo pipefail

if [ "$(psql -X -At -c "SELECT count(*) FROM pg_available_extensions WHERE name='probekit'")" != 1 ]; then
    echo "probekit is not installed on this server; inventory check skipped" >&2
    exit 2
fi

ext_db="lr_inv_ext_$$"
script_db="lr_inv_script_$$"
cleanup() { dropdb --if-exists "$ext_db" >/dev/null 2>&1 || true; dropdb --if-exists "$script_db" >/dev/null 2>&1 || true; }
trap cleanup EXIT

createdb "$ext_db"
createdb "$script_db"

psql -X -q -v ON_ERROR_STOP=1 -d "$ext_db" -c "CREATE EXTENSION probekit; CREATE EXTENSION pg_limit_runway"
psql -X -q -v ON_ERROR_STOP=1 -d "$script_db" -c "CREATE EXTENSION probekit"
PGDATABASE="$script_db" psql -X -q -v ON_ERROR_STOP=1 -f scripts/sql/install.sql

query="SELECT (o->>'class') || '|' || (o->>'identity')
         FROM jsonb_array_elements((probekit.snapshot())->'objects') o
        WHERE o->>'class' NOT IN ('extension', 'extension_config')
          AND o->>'identity' NOT LIKE 'public.limit_runway_script_install%'
          AND o->>'identity' NOT LIKE 'public._limit_runway_script_install%'
        ORDER BY 1"
psql -X -At -d "$ext_db" -c "$query" > /tmp/lr_inv_ext.$$
psql -X -At -d "$script_db" -c "$query" > /tmp/lr_inv_script.$$

if ! diff -u /tmp/lr_inv_ext.$$ /tmp/lr_inv_script.$$; then
    echo "FAIL: inventory differs between CREATE EXTENSION and the script route" >&2
    rm -f /tmp/lr_inv_ext.$$ /tmp/lr_inv_script.$$
    exit 1
fi
rm -f /tmp/lr_inv_ext.$$ /tmp/lr_inv_script.$$
echo "PASS: both routes install the same objects, with the marker table as the only difference"
