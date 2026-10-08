# pg_limit_runway

**What will break next.** Every hard limit in the database, and the date each one is reached.

Part of [pg_incident_watch](../pg_incident_watch/). Pure SQL, `CREATE EXTENSION pg_limit_runway`, no
restart, no `shared_preload_libraries`. Status on 2026-10-08: design only, nothing built. Source:
`pg_incident_watch-overview.md.pdf`, Draft v0.1.

## Overview

Some outages arrive on a schedule. A percentage full tells you little; "runs out on 14 March at the
current rate" tells you when to schedule the fix. pg_limit_runway samples everything with a hard
limit and reports when each will be reached, soonest first.

### The limits it watches

| Limit | What "runs out" means | Where the evidence is |
|---|---|---|
| **`int4` / `int2` sequences and identity columns** | `nextval()` fails, or the value no longer fits the column | `pg_sequences`, `pg_attribute`, `pg_depend` (to tie a sequence to its column) |
| **`int4` foreign keys pointing at widened keys** | The parent is `bigint`, the child column is still `int4`, and inserts fail once the parent passes 2^31 | `pg_constraint` (`conkey`, `confkey`) joined to both columns' types |
| **Transaction ID wraparound** | The server refuses new XIDs | `age(datfrozenxid)`, `age(relfrozenxid)` per table |
| **MultiXact wraparound** | The same, for MultiXact IDs, and also MultiXact member space | `mxid_age(datminmxid)`, `mxid_age(relminmxid)` |
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
  never a password.
- **Detect**: `NOTIFY` on the `limit_runway` channel when a limit crosses into a configured window
  (for example "within 30 days"), again when the window halves, and when it clears, in the shared
  payload format.
- **Review**: the sampled values, which are also where the rate comes from.

## Next steps

In order. Steps 1 to 3 settle what the tool says; 4 onwards build it.

### 1. Wait for, or write, the shared contract

Payload keys, `event` vocabulary, channel naming, version floor and naming conventions are decided
once in [pg_incident_watch](../pg_incident_watch/README.md#next-steps). The recommended floor is
PG 15.

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

### 3. Get the limits right, one at a time, with fixtures

As pg_lock_tree did with `scenarios/`: build each case for real. The traps worth a fixture each:

1. **`serial` on PG 9.x-era schemas**: the sequence is `bigint`, the column is `int4`. The limit is
   the column's, not the sequence's. Resolve the column through `pg_depend`.
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

### 4. The first version: current state only

`limit_runway` (view) and `limit_runway_text()`, every limit with current value, limit, and "no rate
yet". Useful the day it is installed, and it is where the type and catalog logic is tested.

### 5. Add history and dates

`limit_runway_sample()`, a history table, and the projection. Keep the sample cheap: it must not
`SELECT max(id)` on large tables, which is why columns without a sequence (application-generated
keys) are out of scope for v1 and should be listed as "not watched" rather than silently skipped.

### 6. Act and detect

`limit_runway_command()` and `limit_runway_notify()` / `_notify_resolved()` under the shared
contract. Alert on time windows, not percentages: "within 30 days" is the trigger, and escalation is
the window halving (30, 15, 7, 3, 1), the same doubling idea pg_lock_tree uses for waits, run in
reverse.

### 7. Docs, grants and the matrix

`INSTALL.md` with the exact grants. Most of this reads catalogs any role can see, but
`pg_stat_activity` for connection counts needs `pg_read_all_stats`, and some control functions are
superuser-only by default; list exactly which are needed and what is reported without them. Run on
the shared matrix.

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
