#!/usr/bin/env bash
# check-pg-versions.sh: the GitHub matrix has no hole, any other workflow runs only versions the
# matrix declares, and every scenario has committed evidence for every matrix version.
#
# Why this exists. The GitHub matrix once ran 14 and 18 only, and the documentation and the Forgejo
# workflow both described that sample as the range. A version set with a hole in it passes every
# other check here: the doc-claims checker reads the endpoints a document states, never the versions
# a workflow runs. This one reads the workflows and the evidence directory.
#
# What it checks:
#   1. the GitHub matrix is a contiguous run, lo..hi, with no hole: 14, 15, 16, 17, 18, not 14, 18.
#   2. every version another workflow runs is one the matrix declares, so no version is tested only
#      off to the side and none is invented.
#   3. every scenario has a committed evidence file for every matrix version, so ci/job.sh has one
#      to byte-compare.
#
# A workflow on a platform that cannot run every version is a gap stated in that workflow, not a
# failure here: only the versions a workflow actually runs are compared, and they must be a subset
# of the matrix.
set -eu

die() { echo "  FAIL  $*" >&2; exit 1; }

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$here"

gh=".github/workflows/ci.yml"
[ -f "$gh" ] || die "no $gh to read the matrix from"

# The versions the matrix declares. Same pattern as scripts/check-pg-matrix-claims.sh, so the two
# cannot disagree about what the matrix is.
versions=$(grep -oE '"1[0-9](beta[0-9]+)?"' "$gh" | tr -d '"' | sed 's/beta.*//' | sort -n -u)
[ -n "$versions" ] || die "no PostgreSQL versions found in $gh; the pattern has stopped matching, which is a failure of this check"

lo=$(printf '%s\n' "$versions" | head -1)
hi=$(printf '%s\n' "$versions" | tail -1)

# 1. No hole in the range.
hole=""
v=$lo
while [ "$v" -le "$hi" ]; do
    printf '%s\n' "$versions" | grep -qx -- "$v" || hole="$hole $v"
    v=$((v + 1))
done
[ -z "$hole" ] || die "the matrix in $gh skips$hole between $lo and $hi; run every stable version, not a sample"

echo "  matrix: $lo to $hi, no hole ($(printf '%s' "$versions" | tr '\n' ' '))"

# 2. Any other workflow that pins versions runs a subset of the matrix. The versions are read from
#    the evidence glob it compares, .../evidence/*.pg<v>.txt, which names each version it pinned.
for wf in .github/workflows/*.yml .forgejo/workflows/*.yml; do
    [ -f "$wf" ] || continue
    [ "$wf" = "$gh" ] && continue
    wfv=$(grep -oE '\.pg[0-9]+\.txt' "$wf" | grep -oE '[0-9]+' | sort -n -u || true)
    [ -n "$wfv" ] || continue
    extra=""
    for w in $wfv; do
        printf '%s\n' "$versions" | grep -qx -- "$w" || extra="$extra $w"
    done
    [ -z "$extra" ] || die "$wf runs PostgreSQL$extra, which the matrix in $gh does not declare"
    echo "  $wf runs $(printf '%s' "$wfv" | tr '\n' ' '), which the matrix covers"
done

# 3. Every scenario has evidence for every matrix version.
missing=""
for s in scenarios/s[0-9]*_*.sh; do
    [ -f "$s" ] || continue
    name=$(basename "$s" .sh)
    for v in $versions; do
        [ -f "scenarios/evidence/$name.pg$v.txt" ] || missing="$missing $name.pg$v"
    done
done
[ -z "$missing" ] || die "no committed evidence for a matrix version:$missing"

scen=$(ls scenarios/s[0-9]*_*.sh | wc -l | tr -d ' ')
nv=$(printf '%s\n' "$versions" | wc -l | tr -d ' ')
echo "  $scen scenarios, each with evidence for all $nv matrix versions"
