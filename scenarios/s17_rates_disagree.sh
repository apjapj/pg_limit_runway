#!/usr/bin/env bash
# s17 (0.2): the 7-day slope beside the 24-hour slope. rate.md: when they differ by more than a factor of
# two the finding gives both rather than choosing, and the row is ranked by the sooner date.
#   s17_jobs.id: 100 calls used a week back, 165 half a day back, 215 now: about 16 a day over the week,
#                100 a day over the last half day.
. "$(dirname "$0")/lib.sh"
setup_schema
use_extension || skip "pg_limit_runway is not installed on this server"
take_base
psql_q -c "CREATE SEQUENCE $SCHEMA.s17_jobs_seq AS int MAXVALUE 1000" \
       -c "CREATE TABLE $SCHEMA.s17_jobs (id int PRIMARY KEY DEFAULT nextval('$SCHEMA.s17_jobs_seq'))" \
       -c "ALTER SEQUENCE $SCHEMA.s17_jobs_seq OWNED BY $SCHEMA.s17_jobs.id" >/dev/null
psql_q -c "SELECT setval('$SCHEMA.s17_jobs_seq', 100)" >/dev/null; sample_at '7 days' >/dev/null
psql_q -c "SELECT setval('$SCHEMA.s17_jobs_seq', 165)" >/dev/null; sample_at '12 hours' >/dev/null
psql_q -c "SELECT setval('$SCHEMA.s17_jobs_seq', 215)" >/dev/null; sample_at '0' >/dev/null

say "the two slopes"
psql -X -P pager=off -c "
SELECT samples, round(rate_7d, 2) AS per_day_7d, round(rate_24h, 2) AS per_day_24h,
       round(extract(epoch FROM until_7d - newest_at) / 86400, 2) AS days_left_7d,
       round(extract(epoch FROM until_24h - newest_at) / 86400, 2) AS days_left_24h
  FROM limit_runway_projection('sequence', '$SCHEMA.s17_jobs.id')"

finding "$SCHEMA.s17_%"

say "checks"
assert_true "the week ran at 115 calls in 7 days" "$(val "SELECT round(rate_7d, 6) = round(115 / 7.0, 6) FROM limit_runway_projection('sequence', '$SCHEMA.s17_jobs.id')")"
assert_true "the last half day ran at 100 a day, more than twice that" "$(val "SELECT rate_24h = 100 AND rate_24h > 2 * rate_7d FROM limit_runway_projection('sequence', '$SCHEMA.s17_jobs.id')")"
assert_true "the row is ranked by the sooner date, the 24-hour one" "$(val "SELECT f.until_date = p.until_24h FROM limit_runway_findings() f, limit_runway_projection('sequence', '$SCHEMA.s17_jobs.id') p WHERE f.object = '$SCHEMA.s17_jobs.id'")"
assert_finding $SCHEMA.s17_jobs.id projected '%failed inserts included%' '' '%at 16.43 per day, from 3 samples over 7 days%the last 24 hours ran at 100 per day, which gives%' 2
say "expected finding"
note "s17_jobs.id: both rates and both dates in the detail, ranked by the sooner. The week's 16 a day"
note "alone would put it 47 days out, outside the date window; the last day's 100 puts it under 8."
