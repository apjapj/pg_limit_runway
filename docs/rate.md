# rate: how "runs out on" is measured, and when it is not a rate at all

**For: whoever writes the sampler and the projection, and whoever has to trust a date it prints.**
pg_limit_runway's headline is a date: "`orders.id` (int4) runs out on 14 March at the current rate".
This document settles what "the current rate" means before any SQL. Every figure links to the scenario
evidence it comes from, and `scenarios/check-evidence.sh` fails if one does not.

## A date needs two observations

A rate is a slope, and one sample is a point. With one sample the tool reports the current value and the
limit and says **no rate yet**; it never invents a date. This holds for every limit below that has a rate.

The slope is taken over the **last 7 days** of samples, with the **last 24 hours** shown beside it, so a
recent acceleration is visible rather than averaged away. Where the two disagree by more than a factor
of two, the finding says so instead of picking one.

## Per limit: what is sampled, and what the scenarios found

**Sequences and identity columns** (s1 to s4, s12, s13). Sampled: `last_value` and `is_called`, read
from the sequence itself, since `pg_sequences` hides the position until the first call and so misses
`setval(..., false)`. Rate: calls of `nextval()` per day. The limit is the *column's* type, reached through `pg_depend`, not the sequence's (s1: a bigint
sequence feeding an int4 column, at [0.000000](../scenarios/evidence/s1_serial_bigint_seq.pg18.txt)% by the usual check
and already failing), or the sequence's own `MAXVALUE` where that is lower
(s3: [1000](../scenarios/evidence/s3_negative_maxvalue_cycle.pg18.txt) on a bigint column), or `min_value` for a
descending sequence.

**A sequence that is not owned by a column is still reported, and its own `MAXVALUE` is then the
whole limit.** An `OWNED BY`, or the identity column that creates one implicitly, is the only thing
that ties a sequence to a column, and without it there is no column type to be the limit. The
sequence is not skipped: it appears with the table and column fields empty and the limit taken from
its own bounds. Measured on 18, three sequences side by side. The `bigserial` on a `bigint` column reported `colmax`
9223372036854775807 and the same effective limit. A `bigint` sequence owned by an `int4` column
reported `colmax` 2147483647 and an effective limit of 2147483647, the column winning over the
sequence's own much larger `MAXVALUE`, which is the rule above. A bare `CREATE SEQUENCE standalone
MAXVALUE 100` reported an empty `coltype` and `colmax` and an effective limit of 100. Two things the scenarios showed that change how the rate is read:
- **a failed insert still consumes a value.** In s1 the sequence stood at
  [2147483648](../scenarios/evidence/s1_serial_bigint_seq.pg18.txt) after the insert that overflowed, past the column's
  maximum, so "values left" was [-1](../scenarios/evidence/s1_serial_bigint_seq.pg18.txt). The rate counts attempts, not
  rows, and a sequence past its column's maximum is reported **exhausted**, never as a negative count;
- **CYCLE has no exhaustion date** (s3): `nextval()` wrapped to [1](../scenarios/evidence/s3_negative_maxvalue_cycle.pg18.txt)
  and the insert collided. A cycling sequence is projected to its wrap, and the finding is "will collide",
  not "will run out";
- **"values left" counts calls, in steps of the increment**, from the value the next call hands out. An
  earlier 0.1 counted the values between the position and the limit, which is right only for an increment
  of 1: s13's descending sequence by 3 stood [2](../scenarios/evidence/s13_descending_cycle_and_step.pg18.txt) above its
  floor and its next call failed. A truth table of 32 shapes (increments 1, -1, 3, -3, cycling or not, at
  the end, one step before it, mid-way, never called), measured by calling `nextval()` on 14 and 18, is now
  a pgTAP test: the count equals the calls that succeed, and "exhausted" means none do.

**State first, then a rate.** Before any projection, a sequence is checked against its data: if keys
already exist where the sequence is heading (`max(id)` at or past the next value for an ascending
sequence, `min(id)` for a descending one), the sequence is *behind the data* (s12, rows loaded with
explicit ids and the sequence never advanced) or, for a cycling sequence, has *cycled into existing keys*
(s3, s13). That is reported as a state with no count and no projection: a subtraction there goes negative
and the usual percentage exceeds 100, and neither is a number the tool may print. One more index lookup
says whether the very next default id is taken, so the finding says "the next insert fails" only when it
does. The fix is named for a sequence that does not cycle (`setval` to the end of the data, which the tool
will not run, being read-only); for a cycling one no `setval` is a fix, since it would wrap straight back
into the same keys, and the finding says so. The end of the data is read through an index whose leading
column is the column (s12's plan used it); a column with no such index is "not established", never
scanned. Otherwise the count, and later the projection, proceed from the position.

**Before the wrap, a cycling sequence keeps its count.** Piotr's review of 0.1 asked whether a descending
CYCLE sequence's count was the distance past its floor rather than the values remaining, and proposed
giving no cycling sequence a count at all. Measured: s13's descending cycling sequence was given
[4](../scenarios/evidence/s13_descending_cycle_and_step.pg18.txt) values left before the wrap, and exactly that many inserts
then succeeded; every cycling shape in the truth table agreed once the count was in steps. So the count is
true and is kept, phrased "N of M values left before it wraps to X", with the `then:` line that inserts
after the wrap collide with any keys still held. After the wrap there is no count: the state is "cycled into
existing keys". A cycling sequence whose column is narrower than its range fails at the column's limit
before it wraps, and is counted as one that does not cycle.

**The rate counts attempts, which the tool cannot see.** Every insert that fails after `nextval()` still
consumes a value (s1), so a sequence advances faster than rows arrive by an amount no catalog records. The
projected date therefore carries an error band the tool cannot narrow, and the finding says the date is
"at the current rate of consumption, including failed inserts" rather than presenting it as exact.

**Foreign keys narrower than their parent** (s4). The rate is the *parent's* sequence; the limit is the
child column's type. s4's parent was at [2147483648](../scenarios/evidence/s4_widened_parent_fk.pg18.txt) with the usual
check under 0.001%, and the child could no longer reference it.

**Transaction IDs** (s5). Sampled: `age(datfrozenxid)` per database and the current xid read with
`pg_snapshot_xmax(pg_current_snapshot())`, which s5 showed assigns nothing, while `pg_current_xact_id()`
assigns one: a sampler built on it consumes what it measures. Rate: xids per day. Distances reported:
to `autovacuum_freeze_max_age` ([200000000](../scenarios/evidence/s5_xid_age.pg18.txt) by default), to
`vacuum_failsafe_age` ([1600000000](../scenarios/evidence/s5_xid_age.pg18.txt)) and to wraparound at
[2147483648](../scenarios/evidence/s5_xid_age.pg18.txt). **A forced vacuum is not a reset:** in s5 the anti-wraparound
vacuum ran on a table with autovacuum off, and froze nothing, because it freezes only rows older than
`vacuum_freeze_min_age`. The age is sampled after a vacuum, never assumed to have fallen.

**MultiXact IDs** (s6). Sampled: `mxid_age(datminmxid)`. Rate: multixacts per day, **measured, never
derived from row counts**: s6 made [100](../scenarios/evidence/s6_multixact.pg18.txt) multixacts from 100 rounds of two
lockers over 50 rows, not 5000, because one multixact serves every row locked by the same set of
transactions. **Member space is not established for a monitoring role**: listing `pg_multixact/members`
needs superuser, and a `pg_monitor` role is refused.

**Replication slots** (s8). With `max_slot_wal_keep_size` set, sampled: `safe_wal_size` and
`pg_current_wal_lsn()`; rate: WAL bytes per day; the date is when `safe_wal_size` reaches zero and the
slot is invalidated (s8 reached `lost`). **Unset**, `safe_wal_size` is NULL and nothing invalidates the
slot; the limit is the disk holding `pg_wal`, which this tool cannot read without file access, so it is
reported as retained WAL growing, not as a date.

## Limits that do not have a rate

- **Passwords** (s9): `rolvaliduntil` is a fixed date, [3](../scenarios/evidence/s9_valid_until.pg18.txt) days away for
  `lr_scen_soon`. No projection; `infinity` and NULL never expire. Expiry refuses password logins only.
- **Partitions** (s7): the last range partition's upper bound is a fixed boundary, `2026-03-01` in s7,
  with no projection. Non-time keys are skipped.
- **Connections** (s10): a peak against a limit, per server, per role and per database, not a slope.
  s10's role had [2](../scenarios/evidence/s10_connection_headroom.pg18.txt) of 2 in use while the server had
  [97](../scenarios/evidence/s10_connection_headroom.pg18.txt) slots for ordinary roles. Reported as the highest use over the
  window once there is history; 0.1 has none, so it reports the current count, labelled "current, not a
  peak". Counting needs `pg_read_all_stats`; without it a role's counts would read low, so they are "not
  established" instead (INSTALL.md).
