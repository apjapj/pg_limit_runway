# pg_limit_runway

[![CI](https://github.com/apjapj/pg_limit_runway/actions/workflows/ci.yml/badge.svg)](https://github.com/apjapj/pg_limit_runway/actions/workflows/ci.yml)
[![Licence: PostgreSQL](https://img.shields.io/badge/licence-PostgreSQL-blue.svg)](LICENSE)

**What will break next.** Every hard limit in the database, and the date each one is reached.

Part of [pg_incident_watch](https://github.com/apjapj/pg_incident_watch). Pure SQL, `CREATE EXTENSION pg_limit_runway`, no
restart, no `shared_preload_libraries`. Status: **0.5.0**, with history, projected
dates, alerting and the statements to act on them, tested on PostgreSQL 14 to 18. Install and grants:
[INSTALL.md](INSTALL.md). What changed in each release: [CHANGELOG.md](CHANGELOG.md). Changing it or
releasing it: [CONTRIBUTING.md](CONTRIBUTING.md).

## Overview

Some outages arrive on a schedule. A percentage full tells you little; "runs out on 14 March at the
current rate" tells you when to schedule the fix. pg_limit_runway samples everything with a hard
limit and reports when each will be reached, soonest first.

### The limits it watches

| Limit | What "runs out" means | Where the evidence is |
|---|---|---|
| **`int4` / `int2` sequences and identity columns** | `nextval()` fails, or the value no longer fits the column | `pg_sequence`, the sequence's own `last_value`/`is_called`, `pg_attribute`, `pg_depend` (to tie a sequence to its column). A sequence is tied to a column by `ALTER SEQUENCE ... OWNED BY` and **not** by a column `DEFAULT`: without it there is no dependency, the column's limit is invisible, and the sequence is measured against its own `MAXVALUE`, which reports room the next insert does not have. See [docs/rate.md](docs/rate.md) |
| **`int4` foreign keys pointing at widened keys** | The parent is `bigint`, the child column is still `int4`, and inserts fail once the parent passes 2^31 | `pg_constraint` (`conkey`, `confkey`) joined to both columns' types |
| **Transaction ID wraparound** | The server refuses new XIDs | `age(datfrozenxid)`, `age(relfrozenxid)` per table |
| **MultiXact wraparound** | The same, for MultiXact IDs, and also MultiXact member space | `mxid_age(datminmxid)`, database level. `relminmxid` is per table and is not read: the limit is the database's, so there is no per-table MultiXact finding |
| **Time-range partitions** | Inserts beyond the last partition fail, or land in DEFAULT | `pg_partitioned_table`, `pg_inherits`, `pg_get_expr(relpartbound, ...)` |
| **Replication slots near invalidation** | The slot is invalidated and its consumer must be rebuilt | `pg_replication_slots.wal_status`, `safe_wal_size`, `max_slot_wal_keep_size` |
| **Connection headroom** | New connections are refused | `max_connections`, `superuser_reserved_connections`, `reserved_connections` (PG 16+), per-role `rolconnlimit`, per-database `datconnlimit`, `pg_stat_activity` |
| **Role passwords about to expire** | Logins fail | `pg_roles.rolvaliduntil` |

### What a finding looks like

- **Diagnose**: one row per limit, soonest first: what it is, current value, the limit, the observed
  rate, and the projected date, with the sentence form ("`orders.id` (int4) runs out on 14 March at
  the current rate").
- **Act**: the least destructive statement for each. `ALTER TABLE ... ALTER COLUMN ... TYPE bigint`
  is the honest fix for a sequence and also a full table rewrite under `ACCESS EXCLUSIVE`, so the
  command row must say so; `VACUUM (FREEZE)` on the oldest tables for wraparound; `CREATE TABLE ...
  PARTITION OF` with the next range; `ALTER ROLE ... VALID UNTIL` for a password, with the date and
  never a password. The exact statement for each kind, and its note, are settled in
  [docs/act.md](docs/act.md).
- **Detect**: `NOTIFY` on the `limit_runway` channel when a limit crosses into a configured window
  (for example "within 30 days"), again when the window halves, and when it clears, in the shared
  payload format.
- **Review**: the sampled values, which are also where the rate comes from.

## Next steps

In order. Steps 1 to 3 settle what the tool says; 4 onwards build it.

### 1. Wait for, or write, the shared contract

Payload keys, `event` vocabulary, channel naming, version floor and naming conventions are decided
once in [pg_incident_watch](https://github.com/apjapj/pg_incident_watch#next-steps). The floor is
**PostgreSQL 14 and later**. PostgreSQL 14 reaches upstream end of life on 2026-11-12, and the floor is revisited then. Features newer than 14 are
per-feature checks with a stated degradation, never a floor: `reserved_connections` exists only on 16
and later, so on 14 and 15 connection headroom counts `superuser_reserved_connections` alone and says
so.

### 2. Decide how rate is measured, because the headline depends on it

"At the current rate" needs at least two observations. Decide and document:

- **History is required for a date.** Without samples there is a current value and a limit, and the
  view says "no rate yet" rather than inventing one. A sequence's `last_value` and an XID age alone
  give one point.
- **Which window the rate comes from.** Proposed: the slope over the last 7 days of samples, with the
  last 24 hours shown beside it, so a recent acceleration is visible rather than averaged away.
- **Measuring XID consumption without consuming XIDs.** `pg_current_xact_id()` assigns one; read
  `pg_snapshot_xmax(pg_current_snapshot())` instead.
- **Limits that do not have a rate.** Password expiry is a fixed date. Connection headroom is a peak,
  not a slope: report peak used vs available over the window, not a projected date. Partitions run out
  on the upper bound of the last partition, which is a date with no projection at all.

### 3. ~~Get the limits right, one at a time, with fixtures~~ **Done: [scenarios/](scenarios/README.md)**

As pg_lock_tree did with `scenarios/`: build each case for real. The traps worth a fixture each:

1. **`serial` on PG 9.x-era schemas**: the sequence is `bigint`, the column is `int4`. The limit is
   the column's, not the sequence's. Resolve the column through `pg_depend`.
   **A sequence with no owning column** has no column to resolve. It is not skipped: it is reported
   with an empty table and column and its own `MAXVALUE` as the whole limit, so an `OWNED BY` is what
   decides whether a sequence is tied to a table at all. See [docs/rate.md](docs/rate.md).
2. **`int2` identity and sequences**, which run out first.
3. **Sequences with a negative increment, or a custom `MAXVALUE`/`CYCLE`.** `CYCLE` does not fail,
   it wraps and collides with existing keys; report it as a different finding.
4. **A widened parent with an `int4` child foreign key.**
5. **XID age close to `autovacuum_freeze_max_age`** (forced anti-wraparound autovacuum starts) and to
   `vacuum_failsafe_age`, as well as to the hard stop, since the first two are the operational
   warnings and the stop is the outage.
6. **MultiXact**: both ID age and member space. Member-space exhaustion happens before ID wraparound
   on some workloads and is harder to see; find out what is readable without superuser.
7. **Range partitions with and without a DEFAULT**, and partitions on non-time keys, which are out
   of scope and must be skipped rather than misread.
8. **An inactive slot** with `max_slot_wal_keep_size` set and unset; with it unset, the risk is the
   disk filling, not invalidation, and that is a different limit.
9. **A role with `VALID UNTIL`**, and `infinity`.

Built as eleven scenarios, run on PostgreSQL 14 and 18; six of them showed behaviour this list did not
expect (failed inserts consume sequence values, a forced vacuum need not lower the age, MultiXacts are per
locker set, a DEFAULT partition blocks the fix, expired passwords still allow non-password logins,
superusers bypass connection limits). Two more came later: s12, a sequence behind its data (found by
Piotr), and s13, a descending cycling sequence and a descending one stepping by 3 (from Piotr's review
of 0.1), thirteen in all. How rate is measured and how limits are ordered are now decided in
[docs/rate.md](docs/rate.md) and [docs/ranking.md](docs/ranking.md), before any SQL.

### 4. ~~The first version: current state only~~ **Done: 0.1, [INSTALL.md](INSTALL.md)**

`limit_runway` (view) and `limit_runway_text()`, every limit with current value, limit, and "no rate
yet". Useful the day it is installed, and it is where the type and catalog logic is tested.

Built as `limit_runway_findings(min_used, date_window)` behind both, in the three finding states of
[docs/ranking.md](docs/ranking.md). Tested by `test/01_limit_runway.sql` (pgTAP) and by every scenario,
which asserts the extension's finding against its fixture, on 14 to 18. What building it changed:

- The serial finding is a state first: **exhausted** (never a negative count or more than 100%),
  **behind the data** (with the `setval` to run by hand), **cycled into existing keys** (no `setval`
  fixes that, and the finding says so), and only otherwise a count of values left. Behind-the-data is
  read through an index whose leading column is the column, at the end the sequence is heading for; with
  no such index it is "not established", and the table is never scanned.
- The count is of `nextval()` calls, in steps of the increment, from the next value. Counting values
  between the position and the limit was right only for an increment of 1; a truth table of 32 shapes,
  measured by calling `nextval()`, is now a pgTAP test. A cycling sequence keeps its count before the
  wrap ("before it wraps to X"), because the measurement showed it true; [docs/rate.md](docs/rate.md) has
  the decision.
- Connection counts need `pg_read_all_stats`, as step 7 said: measured on 14 and 18, a role without it
  sees other sessions with their type, user and database hidden and would count 0 of N. Such a role gets
  "not established", not a low count.
- Sequences no column owns are watched against their own limits (s3's descending sequence).
- Not in 0.1: MultiXact age per table (`relminmxid`; per database only), and the member-space limit,
  which is "not established" for every role.

### 5. ~~Add history and dates~~ **Done: 0.2, [docs/history.md](docs/history.md)**

Built as `limit_runway_sample()`, `limit_runway_history` and `limit_runway_prune()`, with the
projection in `limit_runway_findings()`, to the four answers recorded in docs/history.md. Five more
scenarios, s15 to s19, and `test/02_history.sql`. What building it changed:

- The 7-day and 24-hour windows reach 10% past their length. Cut exactly, a series sampled hourly for
  a week lost its 7-day point to the second the last tick landed late, and both rates came from the last
  half day; the disagreement test caught it.
- A foreign key whose parent sequence the role cannot read was counted as 0 in 0.1, which is "fine". It
  is now listed as not established, like any other sequence the role cannot read.
- Columns with no sequence are still not listed as "not watched", which the paragraph below asks for. It
  is a later item.

`limit_runway_sample()`, a history table, and the projection. Keep the sample cheap: it must not
`SELECT max(id)` on large tables, which is why columns without a sequence (application-generated
keys) are out of scope for v1 and should be listed as "not watched" rather than silently skipped.

### 6. ~~Act and detect~~ **Done: 0.3.0 alerting, 0.4.0 the command, 0.4.1 its quoting**

`limit_runway_command()` is the Act stage: for each finding it returns the least destructive runnable
statement, its tier and its cost, in `docs/act.md`'s contract, and `limit_runway_notify()` /
`_notify_resolved()` are the Detect stage. Alert on time windows, not percentages: "within 30 days" is
the trigger, and escalation is the window halving (30, 15, 7, 3, 1), the same doubling idea pg_lock_tree
uses for waits, run in reverse. The contract is settled in [docs/command.md](docs/command.md): the five
edges, the three tier labels the command carries, and what a finding with no date does instead. What
building it changed is in the changelog for each release.

### 7. Docs, grants and the matrix

`INSTALL.md` with the exact grants (written with 0.1; revisit as 5 and 6 add objects). Most of this reads catalogs any role can see, but
`pg_stat_activity` for connection counts needs `pg_read_all_stats`, and some control functions are
superuser-only by default; list exactly which are needed and what is reported without them.

`INSTALL.md` is written. The matrix runs **14 to 18** on every push, with the evidence for each
version committed, and 19 is open: its image needs the `include` form and a separate apt major, as
pg_lock_tree's workflow does it. This sentence states the range deliberately, so that
`scripts/check-pg-matrix-claims.sh` has something to check and a later edit to the workflow cannot
leave the documentation claiming a range nobody runs.

## Open questions

- Per-database or cluster-wide? XID wraparound, slots, connections and roles are cluster-wide; the
  sequence and partition checks are per-database. Installing in one database sees the first group
  for everyone and the second only for itself. Say so, or offer a fan-out? (pg_lock_tree declined a
  fan-out sampler; see its roadmap, "Considered and not planned".)
- Disk space is the most common limit of all and is not in the overview. It is not readable from SQL
  without an untrusted extension or `pg_ls_dir`-style access. Out of scope, stated as such?
- Password expiry overlaps with the separate `pg_pwreset` project in subject only. This tool reads
  `rolvaliduntil` and never touches credentials; keep it that way and keep no cross-references.
- Should limits be configurable (custom limits, ignore lists) in v1, or only after people run it?
