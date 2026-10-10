#!/usr/bin/env bash
# ci/job.sh <major>: the whole CI job, runnable anywhere with Docker and psql. Builds a scratch server
# from ci/Dockerfile, runs every scenario, and requires the evidence to equal what is committed, byte for
# byte. Modelled on pg_bloat_cause's ci/job.sh; strict from the start, because these scenarios print no
# ids or timestamps and have been byte-identical across runs on two versions.
set -uo pipefail
v=${1:?usage: ci/job.sh <postgres major version>}
cd "$(dirname "$0")/.."
image="lr-ci:$v"; port=58$v; c="lr-ci-$v"; fail=0
docker build -q --build-arg PG_MAJOR="$v" -t "$image" ci/ >/dev/null || exit 1
docker rm -f "$c" >/dev/null 2>&1
docker run -d --rm --name "$c" -p 127.0.0.1:$port:5432 -e POSTGRES_PASSWORD=test "$image" \
    postgres -c autovacuum_naptime=10s -c log_autovacuum_min_duration=0 >/dev/null || exit 1
trap 'docker rm -f "$c" >/dev/null 2>&1' EXIT
for _ in $(seq 1 60); do pg_isready -q -h 127.0.0.1 -p $port && break; sleep 1; done
sleep 3
export PGHOST=127.0.0.1 PGPORT=$port PGUSER=postgres PGPASSWORD=test LR_CONTAINER=$c
out=$(scenarios/run.sh); printf '%s\n' "$out"
grep -qE 'FAILED' <<<"$out" && fail=1
if git diff --quiet -- "scenarios/evidence/*.pg$v.txt"; then echo "  evidence identical"
else git diff -- "scenarios/evidence/*.pg$v.txt"; echo "EVIDENCE DIFFERS"; fail=1; fi
exit $fail
