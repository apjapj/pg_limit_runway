#!/usr/bin/env bash
# scripts/check-uninstall.sh: the clean-drop contract for pg_limit_runway, using ProbeKit v0.1.0.
#
# Throwaway database, ProbeKit snapshot, a dependent view that must block the drop, DROP EXTENSION
# with no CASCADE, then no extension-owned survivor and no history or alert table. Reinstall last.
# Needs probekit.control and probekit--0.1.0.sql in the server's extension directory.
set -euo pipefail

db="limit_runway_uninstall_check_$$"
cleanup() { dropdb --if-exists "$db" >/dev/null 2>&1 || true; }
trap cleanup EXIT

createdb "$db"
export PGDATABASE="$db"

psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION probekit;
CREATE EXTENSION pg_limit_runway;

INSERT INTO limit_runway_history (sampled_at, kind, object, position, limit_value)
VALUES (now(), 'sequence', 'public.uninstall_seq', 1, 100);
INSERT INTO limit_runway_alert (channel, subject, kind, object, event, urgency, notified_at)
VALUES ('uninstall_check', 'uninstall', 'sequence', 'public.uninstall_seq', 'alerting', 1, now());

CREATE TABLE uninstall_before (doc jsonb);
INSERT INTO uninstall_before SELECT probekit.snapshot('{"run":"uninstall-check"}'::jsonb);
SQL

psql -X -q -v ON_ERROR_STOP=1 -c "CREATE VIEW uninstall_dependent AS SELECT * FROM limit_runway;"
if psql -X -q -v ON_ERROR_STOP=1 -c "DROP EXTENSION pg_limit_runway" >/dev/null 2>&1; then
    echo "FAIL: DROP EXTENSION succeeded with a dependent view" >&2
    exit 1
fi
psql -X -q -v ON_ERROR_STOP=1 -c "DROP VIEW uninstall_dependent;"
psql -X -q -v ON_ERROR_STOP=1 -c "DROP EXTENSION pg_limit_runway;"

psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
DO $check$
DECLARE survivors int;
BEGIN
  SELECT count(*) INTO survivors FROM probekit.survivors((SELECT doc FROM uninstall_before), 'pg_limit_runway');
  IF survivors <> 0 THEN
    RAISE EXCEPTION 'extension-owned survivors after drop: %', survivors;
  END IF;
  IF to_regclass('public.limit_runway_history') IS NOT NULL
     OR to_regclass('public.limit_runway_alert') IS NOT NULL THEN
    RAISE EXCEPTION 'a history or alert table survived the drop';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_limit_runway') THEN
    RAISE EXCEPTION 'pg_extension still has a pg_limit_runway row';
  END IF;
  RAISE NOTICE 'PASS: no extension-owned survivor, and every history/alert table is gone';
END
$check$;
SQL

psql -X -q -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_limit_runway;"
psql -X -q -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM limit_runway;" >/dev/null
echo "PASS: pg_limit_runway reinstalls and limit_runway answers"
