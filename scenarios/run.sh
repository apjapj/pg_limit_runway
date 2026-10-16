#!/usr/bin/env bash
# Run every scenario against the server in the libpq variables, tearing down before each and once at the
# end. Raw output to scenarios/out/<scenario>.pg<major>.txt (ignored); masked copy, which the docs link to,
# to scenarios/evidence/<scenario>.pg<major>.txt (committed). EVIDENCE_DIR overrides the second, which is
# how two runs are compared for reproducibility.
. "$(dirname "$0")/lib.sh"
. "$HERE/mask.sh"
out="$HERE/out"; mkdir -p "$out"
evidence=${EVIDENCE_DIR:-"$HERE/evidence"}; mkdir -p "$evidence"
major=$((VER / 10000))
: > "$RUNDIR/order-warnings"
for s in "$HERE"/s[0-9]_*.sh "$HERE"/s[0-9][0-9]_*.sh; do
    [ -f "$s" ] || continue
    name=$(basename "$s" .sh)
    "$HERE/teardown.sh" >/dev/null
    LR_SCENARIO=$name bash "$s" > "$out/$name.pg$major.txt" 2>&1
    case $? in 0) r=ran ;; 3) r=SKIP ;; *) r=FAILED ;; esac
    [ "$r" = ran ] && grep -q '^  FAIL  ' "$out/$name.pg$major.txt" && r=FAILED
    mask_capture < "$out/$name.pg$major.txt" > "$evidence/$name.pg$major.txt"
    printf '  %-32s %s\n' "$name" "$r"
done
"$HERE/teardown.sh" >/dev/null

# The exact nondeterministic-order rule from the capture: a val() that returned more than one row and
# had no ORDER BY, where the row count is known and not guessed. A set-returning function is excluded
# in lib.sh, because its order is its own. This fails the run: the printed order is the output, and an
# unordered multi-row print can move between runs.
if [ -s "$RUNDIR/order-warnings" ]; then
    printf '\n  nondeterministic-order: %s statement(s) returned more than one row with no ORDER BY:\n' \
        "$(wc -l < "$RUNDIR/order-warnings")"
    sed 's/^/    /' "$RUNDIR/order-warnings"
    echo "  FAILED: nondeterministic-order"
    exit 1
fi
