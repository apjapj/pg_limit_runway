#!/usr/bin/env bash
# ci/job.sh <major>: the whole CI job, runnable anywhere with Docker, psql and pg_prove. Builds a scratch
# server from ci/Dockerfile, installs the extension md5-verified, runs the pgTAP tests, runs every
# scenario (which also check the extension's findings), and requires the evidence to equal what is
# committed, byte for byte. Modelled on pg_bloat_cause's ci/job.sh; strict from the start, because these scenarios print no
# ids or timestamps and have been byte-identical across runs on two versions.
set -uo pipefail
v=${1:?usage: ci/job.sh <postgres major version>}
cd "$(dirname "$0")/.."

# Preflight. This job needs two things from Docker before it can do anything at all: the CLI on
# PATH, and a daemon that answers. A daemon that is not there fails later as "failed to connect to
# the docker API", and the build that follows reads like a bad Dockerfile, so neither the cause nor
# the fix is named. Check both here, where they can be. The same failure hit the Forgejo copy once
# (its ubuntu-latest resolved to an act_runner with no /var/run/docker.sock) and was invisible for
# five runs, so the message names the endpoint it tried.
if ! command -v docker >/dev/null 2>&1; then
    echo "ci/job.sh: the docker CLI is not on PATH" >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ci/job.sh: the docker daemon is not answering${DOCKER_HOST:+ (DOCKER_HOST=$DOCKER_HOST)}" >&2
    echo "           start it, or point DOCKER_HOST at a reachable daemon; this job needs it" >&2
    exit 1
fi

image="lr-ci:$v"; port=58$v; c="lr-ci-$v"; fail=0
docker build -q --build-arg PG_MAJOR="$v" -t "$image" ci/ >/dev/null || exit 1
docker rm -f -v "$c" >/dev/null 2>&1
docker run -d --rm --name "$c" -p 127.0.0.1:$port:5432 -e POSTGRES_PASSWORD=test "$image" \
    postgres -c autovacuum_naptime=10s -c log_autovacuum_min_duration=0 >/dev/null || exit 1
trap 'docker rm -f -v "$c" >/dev/null 2>&1' EXIT
for _ in $(seq 1 60); do pg_isready -q -h 127.0.0.1 -p $port && break; sleep 1; done
sleep 3
export PGHOST=127.0.0.1 PGPORT=$port PGUSER=postgres PGPASSWORD=test PGDATABASE=postgres LR_CONTAINER=$c
scenarios/install-extension.sh "$c" || exit 1
pg_prove --dbname postgres test/*.sql || fail=1
out=$(scenarios/run.sh); printf '%s\n' "$out"
grep -qE 'FAILED' <<<"$out" && fail=1
if git diff --quiet -- "scenarios/evidence/*.pg$v.txt"; then echo "  evidence identical"
else git diff -- "scenarios/evidence/*.pg$v.txt"; echo "EVIDENCE DIFFERS"; fail=1; fi

step "docker footprint"
# The smoke alarm for the anonymous-volume leak the removal paths fix at source: a host that
# accumulates dangling volumes fails here rather than filling its disk. Deletes nothing.
scripts/docker-guard.sh check || fail=1

exit $fail
