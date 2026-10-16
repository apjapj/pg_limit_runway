#!/usr/bin/env bash
# scripts/lint.sh: every database-free check, in one script. No Makefile and no PostgreSQL.
#
# Why this is a script and not the `lint` recipe. `make lint` parses the Makefile first, and the
# Makefile includes $(PGXS) unconditionally, so `make lint` needs pgxs.mk to exist. The Forgejo lint
# runner has pg_config and no postgresql-server-dev, so `make lint` stopped at the include and no
# check ran at all. A lint that needs a PostgreSQL toolchain to check shell scripts is the wrong
# dependency. `make lint` calls this, and both CI copies call it directly; scripts/check-ci-parity.sh
# holds the copies to the same command.
#
# Everything here is text and git only: no database, no network, no superuser, so it is safe
# anywhere and cheap enough for a pre-commit hook.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$1"; }

# The version agrees across control, the newest release and the README header, every SQL file is
# installed with no DATA duplicate, doc paths resolve, the test plans match, and no em-dashes.
step "the documentation's claims"
./scripts/lint-docs.sh
# Every catalog a README feature table names is one the release script reads.
step "README catalog claims"
./scripts/check-evidence-claims.sh
# A document that states the PostgreSQL range the matrix covers must state the range CI declares.
step "the stated PostgreSQL range"
./scripts/check-pg-matrix-claims.sh
# The matrix has no hole, another workflow runs only versions it declares, and every scenario has
# evidence for every matrix version.
step "the version matrix"
./scripts/check-pg-versions.sh
# The two CI copies define the same jobs and run the same command for the ones they share. Vendored
# from pg-dev-infra; run with bash, it has no shebang.
step "the two CI copies agree"
bash ./scripts/check-ci-parity.sh
# Every vendored harness copy still matches the sha256 in its own header. The canonical is private,
# so this is the in-repo half of the sync. Vendored from pg-dev-infra; run with bash.
step "the vendored harness matches its headers"
bash ./scripts/check-vendored-hashes.sh
# Every figure a document links to scenario evidence is in that file.
step "evidence figures"
./scenarios/check-evidence.sh
# Rejects a duplicated mapping key, which PyYAML accepts silently and Forgejo does not.
step "workflows"
./scripts/check-workflows.sh
