#!/usr/bin/env bash
# Do the SQL examples in the documentation still work?
#
# Nothing else in this repository executes them. `scripts/lint-docs.sh` checks that the names inside
# them exist and that their links resolve, but not that the statements parse or plan. pg_lock_tree
# gained this check after `SELECT * FROM lock_tree_replay(42)` sat in its docs since 0.14 and was
# never run; the same wrong example is possible here, and INSTALL.md carries five SQL blocks.
#
# Every fenced block tagged sql, or untagged and starting with a query keyword, is split into
# statements and handed to EXPLAIN. EXPLAIN parses and plans without executing, so nothing is written
# and nothing is locked, and the check is safe against a live database.
#
# Only queries are planned. GRANT, SET, ALTER, CALL, DROP, COPY and DO are legitimate examples that
# EXPLAIN cannot parse, and a psql meta-command such as \gexec is not SQL at all, so testing those
# proves nothing either way.
#
# EXPECTED_FAILURES lists statements that cannot plan here for a stated reason. Anything else that
# fails is a defect in the documentation, and adding to that list needs the reason written down
# beside it.
set -u

cd "$(dirname "$0")/.." || exit 1

: "${PGHOST:=127.0.0.1}"
: "${PGDATABASE:=postgres}"
: "${PGUSER:=postgres}"
export PGHOST PGDATABASE PGUSER

# Each entry is a substring of the error, and why it is tolerated.
EXPECTED_FAILURES=(
    'schema "cron" does not exist|INSTALL.md offers pg_cron as one way to schedule the sampler; it is not required and is not installed here'
)

# Is the statement's ORDER BY on a unique key? If it is, ties cannot reorder and the result is
# deterministic. If it is not, the ORDER BY settles the groups but not the order within them, which
# is the tie-break rule. It answers NO only when it can see the key is not unique: an ORDER BY it
# cannot parse (a join, an expression) returns YES, so this warns and never fails on a guess.
order_is_unique() {
    local stmt=$1 tbl cols cl n
    tbl=$(printf '%s' "$stmt" | grep -oiE 'FROM +[A-Za-z0-9_."]+' | head -1 | sed -E 's/^FROM +//; s/"//g')
    cols=$(printf '%s' "$stmt" | grep -oiE 'ORDER BY +[^;]*' | head -1 \
           | sed -E 's/^ORDER BY +//I; s/ (ASC|DESC)//gI; s/ NULLS (FIRST|LAST)//gI; s/,/ /g; s/"//g; s/ +/ /g')
    [ -n "$tbl" ] && [ -n "$cols" ] || return 0
    cl=$(printf '%s' "$cols" | tr ' ' '\n' | grep -v '^$' | sed "s/.*/'&'/" | paste -sd, -)
    [ -n "$cl" ] || return 0
    n=$(psql -X -tA -c "
        SELECT count(*) FROM pg_index i
          JOIN pg_class c ON c.oid = i.indrelid
          JOIN pg_namespace ns ON ns.oid = c.relnamespace
         WHERE i.indisunique
           AND (ns.nspname || '.' || c.relname = '$tbl' OR c.relname = '$tbl')
           AND (SELECT array_agg(a.attname) FROM pg_attribute a
                 WHERE a.attrelid = c.oid AND a.attnum = ANY (i.indkey))
               <@ (SELECT array_agg(x) FROM unnest(ARRAY[$cl]) x)" 2>/dev/null)
    [ "${n:-0}" -ge 1 ]
}


if ! psql -X -tAc 'SELECT 1' >/dev/null 2>&1; then
    printf '  cannot reach a database at %s:%s/%s, so the examples cannot be checked\n' \
        "$PGHOST" "${PGPORT:-5432}" "$PGDATABASE"
    exit 1
fi
if ! psql -X -tAc "SELECT 1 FROM pg_extension WHERE extname='pg_limit_runway'" | grep -q 1; then
    printf '  pg_limit_runway is not installed in %s, so the examples cannot be checked\n' "$PGDATABASE"
    exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

python3 - > "$tmp" <<'PY'
import re, glob, os

SKIP_DOCS = {'CHANGELOG.md'}   # a historical record: it quotes old releases on purpose

def blocks(text):
    out, cur, inside, lang, start = [], [], False, '', 0
    for i, line in enumerate(text.split('\n'), 1):
        m = re.match(r'^\s*(`{3,}|~{3,})\s*([A-Za-z0-9_+-]*)', line)
        if m:
            if not inside:
                inside, lang, cur, start = True, (m.group(2) or '').lower(), [], i
            else:
                inside = False
                out.append((lang, start, cur))
            continue
        if inside:
            cur.append(line)
    return out

def statements(lines):
    out, buf = [], []
    for l in lines:
        s = l.strip()
        if not s or s.startswith('--'):
            continue
        buf.append(l)
        if s.endswith(';'):
            out.append('\n'.join(buf))
            buf = []
    if buf:
        out.append('\n'.join(buf))
    return out

QUERY = re.compile(r'^\s*(SELECT|WITH|EXPLAIN|TABLE)', re.I)
docdir = 'docs'
for f in sorted(glob.glob('*.md') + glob.glob(os.path.join(docdir, '*.md'))):
    if os.path.basename(f) in SKIP_DOCS:
        continue
    for lang, start, body in blocks(open(f).read()):
        first = next((l for l in body if l.strip() and not l.strip().startswith('--')), '')
        if lang in ('sql', 'psql') or (lang == '' and QUERY.match(first)):
            for i, st in enumerate(statements(body), 1):
                print('%s\t%d\t%d\t%s' % (f, start, i, ' '.join(st.split())))
PY

total=0
checked=0
skipped=0
failed=0
warns=0
declare -a failures

while IFS=$'\t' read -r file line idx stmt; do
    total=$((total + 1))
    # Placeholders and dollar quoting are prose, not statements to plan. The placeholder test is an
    # angle-bracket PAIR: skipping any statement with `<` or `>` skipped every named-argument example,
    # and a planted typo then reported 0 failures.
    case "$stmt" in
        *'...'*|*'<'*'>'*|*'$$'*|*'\\'*)
            skipped=$((skipped + 1)); continue ;;
    esac
    case "$stmt" in
        SELECT*|WITH*|EXPLAIN*|TABLE*|'('SELECT*) ;; *)
            skipped=$((skipped + 1)); continue ;;
    esac
    case "$stmt" in
        *gexec*|*gset*)
            skipped=$((skipped + 1)); continue ;;
    esac

    err=$(psql -X -tA -c "EXPLAIN (COSTS OFF) $stmt" 2>&1 >/dev/null | head -1)
    if [ -z "$err" ]; then
        checked=$((checked + 1))
        # It plans. Now judge the order, which is a warning here and not a failure: EXPLAIN shows the
        # plan but not the rows. The scenario capture, where the row count is known, is the exact rule.
        plan=$(psql -X -tA -c "EXPLAIN (COSTS OFF) $stmt" 2>/dev/null)
        top=$(printf '%s\n' "$plan" | sed -n '1s/^ *//p')
        case "$top" in
            Sort*|"Incremental Sort"*)
                if ! order_is_unique "$stmt"; then
                    warns=$((warns + 1))
                    printf '  WARN  %s:%s  tie-break: the ORDER BY is not on a unique key, so tied rows have no settled order\n          %s\n' \
                        "$file" "$line" "$stmt"
                fi ;;
            Aggregate*|Result*)
                : ;;   # one row by construction
            Limit*)
                if ! printf '%s' "$stmt" | grep -qiE 'LIMIT 1([^0-9]|$)'; then
                    warns=$((warns + 1))
                    printf '  WARN  %s:%s  nondeterministic-order: a Limit without a unique order may return rows in any order\n          %s\n' \
                        "$file" "$line" "$stmt"
                fi ;;
            *)
                if printf '%s' "$stmt" | grep -qE '(FROM|JOIN) +[A-Za-z0-9_.]+ *\('; then
                    :   # a set-returning function: its own order, not the planner's to settle
                else
                    warns=$((warns + 1))
                    printf '  WARN  %s:%s  nondeterministic-order: the plan is not ordered (%s) and may return more than one row in any order\n          %s\n' \
                        "$file" "$line" "${top%% *}" "$stmt"
                fi ;;
        esac
        continue
    fi

    tolerated=''
    for entry in ${EXPECTED_FAILURES+"${EXPECTED_FAILURES[@]}"}; do
        pat=${entry%%|*}
        case "$err" in
            *"$pat"*) tolerated=${entry#*|}; break ;;
        esac
    done
    if [ -n "$tolerated" ]; then
        skipped=$((skipped + 1))
        printf '  known  %s:%s  %s\n' "$file" "$line" "$tolerated"
        continue
    fi
    failed=$((failed + 1))
    failures+=("$file:$line  $(printf '%s' "$err" | cut -c1-110)
    $stmt")
done < "$tmp"

printf '\n  %d example statements: %d plan cleanly, %d not planned, %d failed, %d warned (nondeterministic-order, tie-break)\n' \
    "$total" "$checked" "$skipped" "$failed" "$warns"

for f in ${failures+"${failures[@]}"}; do
    printf '  FAIL  %s\n' "$f"
done

[ "$failed" -eq 0 ] || exit 1
