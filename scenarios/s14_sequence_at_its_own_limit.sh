#!/usr/bin/env bash
# s14: a sequence standing at exactly its own MAXVALUE or MINVALUE. Raised by Piotr's review of 0.1:
# the exhausted sentence said "the next value would be N", and at the sequence's own ceiling there is
# no next value. nextval() raises "reached maximum value" and hands out nothing, so the message named
# a number the server had already refused to produce, and an operator saw the two disagree.
#   s14_ceiling:  ascending, MAXVALUE 100, sitting at 100, with a column that is wide enough to hold
#                 101. There is no column limit in the way, so only the sequence's own ceiling stops it.
#   s14_floor:    descending, MINVALUE 1, sitting at 1. The same, at the other end.
#   s14_narrow:   the contrasting case, where the COLUMN is the limit and the sequence has further to
#                 go: MAXVALUE 100000 on a smallint column, standing at 32767. There the sequence
#                 does hand out 32768, and smallint is what refuses it, so the two sentences differ.
. "$(dirname "$0")/lib.sh"
setup_schema
psql_q -c "CREATE SEQUENCE $SCHEMA.s14_ceil_seq AS int INCREMENT 1 MINVALUE 1 MAXVALUE 100 START 100" \
       -c "CREATE TABLE $SCHEMA.s14_ceil (id int PRIMARY KEY DEFAULT nextval('$SCHEMA.s14_ceil_seq'))" \
       -c "ALTER SEQUENCE $SCHEMA.s14_ceil_seq OWNED BY $SCHEMA.s14_ceil.id" \
       -c "INSERT INTO $SCHEMA.s14_ceil DEFAULT VALUES" \
       -c "CREATE SEQUENCE $SCHEMA.s14_floor_seq AS int INCREMENT -1 MINVALUE 1 MAXVALUE 100 START 1" \
       -c "CREATE TABLE $SCHEMA.s14_floor (id int PRIMARY KEY DEFAULT nextval('$SCHEMA.s14_floor_seq'))" \
       -c "ALTER SEQUENCE $SCHEMA.s14_floor_seq OWNED BY $SCHEMA.s14_floor.id" \
       -c "INSERT INTO $SCHEMA.s14_floor DEFAULT VALUES" \
       -c "CREATE SEQUENCE $SCHEMA.s14_narrow_seq AS bigint INCREMENT 1 MINVALUE 1 MAXVALUE 100000 START 32767" \
       -c "CREATE TABLE $SCHEMA.s14_narrow (id smallint PRIMARY KEY DEFAULT nextval('$SCHEMA.s14_narrow_seq'))" \
       -c "ALTER SEQUENCE $SCHEMA.s14_narrow_seq OWNED BY $SCHEMA.s14_narrow.id" \
       -c "INSERT INTO $SCHEMA.s14_narrow DEFAULT VALUES" >/dev/null

say "the usual check (pg_sequences: where each stands against its own limits)"
psql -X -P pager=off -c "
SELECT sequencename, increment_by, min_value, max_value, last_value,
       last_value = max_value AS at_ceiling, last_value = min_value AS at_floor
  FROM pg_sequences WHERE schemaname = '$SCHEMA' ORDER BY 1"

finding "$SCHEMA.s14_%"

# Asserted BEFORE the probes below, and the order matters. The ceiling and floor inserts die inside
# nextval(), so they consume nothing and the state is unchanged. s14_narrow is different: nextval()
# succeeds and hands out 32768, and only the INSERT is refused. So the failed insert leaves the
# sequence standing past its limit, and the finding correctly becomes "stands past it at 32768:
# failed inserts still consume values". Checking the wording after the probe would be checking a
# different state than the one the evidence above shows.
use_extension && {
  assert_true "s14_ceiling says the next call fails and names no value above its MAXVALUE" \
    "$(val "SELECT detail LIKE '%the next call fails%100 is the sequence''s MAXVALUE%'
                 AND detail NOT LIKE '%would be 101%' FROM limit_runway_findings(0) WHERE object = '$SCHEMA.s14_ceil.id'")"
  assert_true "s14_floor says the next call fails and names no value below its MINVALUE" \
    "$(val "SELECT detail LIKE '%the next call fails%1 is the sequence''s MINVALUE%'
                 AND detail NOT LIKE '%would be 0%' FROM limit_runway_findings(0) WHERE object = '$SCHEMA.s14_floor.id'")"
  assert_true "s14_narrow names the real next value and says the column is what refuses it" \
    "$(val "SELECT detail LIKE '%next value 32768 is past what smallint can hold%'
                 FROM limit_runway_findings(0) WHERE object = '$SCHEMA.s14_narrow.id'")"
}

say "what actually happens on the next insert"
cerr=$(try_sql "INSERT INTO $SCHEMA.s14_ceil DEFAULT VALUES")
note "s14_ceiling: $cerr"
ferr=$(try_sql "INSERT INTO $SCHEMA.s14_floor DEFAULT VALUES")
note "s14_floor: $ferr"
nerr=$(try_sql "INSERT INTO $SCHEMA.s14_narrow DEFAULT VALUES")
note "s14_narrow: $nerr"
assert_true "s14_narrow's failed insert still consumed 32768, so the finding moves to 'stands past it'" \
  "$(val "SELECT detail LIKE '%stands past it at 32768%'
               FROM limit_runway_findings(0) WHERE object = '$SCHEMA.s14_narrow.id'")"

say "checks"
# The finding must say the call FAILS, and must not name a value above the ceiling. The number that
# would have been named is 101 for the ceiling and 0 for the floor; either appearing in the detail is
# the defect this scenario exists for.
assert_true "s14_ceiling's nextval raises rather than handing out 101" \
  "$([[ "$cerr" == *"reached maximum value"* ]] && echo t || echo f)"
assert_true "s14_floor's nextval raises rather than handing out 0" \
  "$([[ "$ferr" == *"reached minimum value"* ]] && echo t || echo f)"
# The narrow case is different in kind: the sequence does have a next value, 32768, and the COLUMN
# refuses it. So the finding must name 32768 here, and say the column is what will not hold it.
assert_true "s14_narrow fails on the column, not the sequence" \
  "$([[ "$nerr" == *"smallint"* ]] && echo t || echo f)"

say "expected finding"
note "s14_ceiling and s14_floor: exhausted at the sequence's own MAXVALUE or MINVALUE, and the sentence says the"
note "next call fails, because nextval() raises there and hands out nothing. It does not name a value."
note "s14_narrow: exhausted at the COLUMN's limit, with the sequence at 32767 and MAXVALUE 100000, so there"
note "the next value is real and is 32768. What refuses it is smallint, and the sentence says so."