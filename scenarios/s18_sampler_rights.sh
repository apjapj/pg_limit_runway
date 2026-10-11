#!/usr/bin/env bash
# s18 (0.2): the sampler runs with the caller's rights (Piotr, 2026-10-11). Without the grants it says
# what it could not read, and never records a low count.
#   lr_scen_reader:   may read the findings, nothing on the history: the sampler refuses, naming the
#                     grant, and the view says rates are not established.
#   lr_scen_sampler:  SELECT and INSERT on the history, but no SELECT on the scenario's sequence: it
#                     samples what it can read and counts the rest as not established, recording nothing
#                     for them.
. "$(dirname "$0")/lib.sh"
setup_schema
use_extension || skip "pg_limit_runway is not installed on this server"
take_base
psql_q -c "CREATE SEQUENCE $SCHEMA.s18_seq AS int MAXVALUE 1000" \
       -c "CREATE TABLE $SCHEMA.s18 (id int PRIMARY KEY DEFAULT nextval('$SCHEMA.s18_seq'))" \
       -c "ALTER SEQUENCE $SCHEMA.s18_seq OWNED BY $SCHEMA.s18.id" \
       -c "SELECT setval('$SCHEMA.s18_seq', 500)" \
       -c "CREATE ROLE lr_scen_reader" \
       -c "GRANT EXECUTE ON FUNCTION limit_runway_findings(numeric, interval), limit_runway_sample(timestamptz) TO lr_scen_reader" \
       -c "CREATE ROLE lr_scen_sampler" \
       -c "GRANT EXECUTE ON FUNCTION limit_runway_sample(timestamptz) TO lr_scen_sampler" \
       -c "GRANT SELECT, INSERT ON limit_runway_history TO lr_scen_sampler" \
       -c "GRANT USAGE ON SCHEMA $SCHEMA TO lr_scen_sampler" >/dev/null

say "the sampler as a role with no grant on the history"
err=$(psql -X -At -q -c "SET ROLE lr_scen_reader" -c "SELECT * FROM limit_runway_sample()" 2>&1 | grep -E '^(ERROR|HINT)' | sed 's/^psql:[^:]*:[0-9]*: //')
printf '%s\n' "$err" | sed 's/^/  /'

say "the sampler as a role that may write the history but cannot read the sequence"
psql -X -q -P pager=off -c "SET ROLE lr_scen_sampler" -c "SELECT * FROM limit_runway_sample('$BASE') WHERE kind = 'sequence'"

say "the view, for the role with no grant on the history"
note "$(psql -X -At -q -c "SET ROLE lr_scen_reader" -c "SELECT detail FROM limit_runway_findings() WHERE kind = 'history'")"

say "checks"
assert_true "the sampler refuses without INSERT on the history, and names the grant" "$([[ "$err" == *"needs SELECT and INSERT on limit_runway_history; nothing was sampled"* && "$err" == *"GRANT SELECT, INSERT ON limit_runway_history"* ]] && echo t || echo f)"
assert_true "a sequence the sampler cannot read is counted as not established" "$(psql -X -At -q -c "SET ROLE lr_scen_sampler" -c "SELECT not_established >= 1 FROM limit_runway_sample('$BASE'::timestamptz + interval '1 second') WHERE kind = 'sequence'")"
assert_true "and nothing is recorded for it" "$(val "SELECT count(*) = 0 FROM limit_runway_history WHERE object = '$SCHEMA.s18.id'")"
assert_true "while xid age, readable by any role, is recorded" "$(val "SELECT count(*) >= 1 FROM limit_runway_history WHERE kind = 'xid' AND sampled_at = '$BASE'")"
LR_ROLE=lr_scen_reader assert_finding limit_runway_history 'not established' '' 'rates and projected dates are not established%' '' 5
say "expected finding"
note "No grant on the history: the sampler refuses and names it; the view has one not-established row."
note "A sequence the sampler cannot read: counted as not established, and no row is written for it."
