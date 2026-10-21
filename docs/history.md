# history: the sample, the table and the projection (README step 5)

**For: whoever builds or reviews 0.2.** It turns [rate.md](rate.md)'s rules into objects, and every
rule it relies on is stated there with its evidence; this page says how 0.2 implements them, what it
costs, and what it still does not know. The four open questions were answered by Piotr on 2026-10-11
("defaults"); the answers are recorded at the end and the sections above follow them.

## What 0.2 adds

| Object | What it is |
|---|---|
| `limit_runway_history` | one row per limit per sample: when, what, the value, the limit |
| `limit_runway_sample(sampled_at timestamptz DEFAULT NULL)` | reads every limit once and appends to the history. The only writer, and the only thing to schedule. `sampled_at` defaults to the statement's own time; it is a parameter so that fixtures can lay down a series at chosen instants with real sequence consumption between them |
| `limit_runway_prune(older_than interval DEFAULT '35 days')` | deletes samples older than the window, in one statement (below) |
| `limit_runway_findings()`, the view and `limit_runway_text()` | gain a rate, a 24-hour rate beside it, and a projected date, where two samples allow one |

## The table

```sql
CREATE TABLE limit_runway_history (
  sampled_at   timestamptz NOT NULL,
  kind         text        NOT NULL,   -- 'sequence', 'foreign key', 'xid', 'multixact', 'replication slot'
  object       text        NOT NULL,   -- as in the view: schema.table.column, database name, slot name
  position     numeric     NOT NULL,   -- the quantity that moves: calls used, xid age, WAL retained
  limit_value  numeric     NOT NULL,   -- the limit at the time, since it can change (ALTER SEQUENCE, a setting)
  epoch        int         NOT NULL DEFAULT 0,   -- bumped when the series is broken (below)
  PRIMARY KEY (kind, object, sampled_at)
);
-- plus an index on sampled_at for pruning, and pg_extension_config_dump so pg_dump keeps the samples
```

The draft had a `state` column, the 0.1 state at each sample. It is not built: nothing reads it, the
state is recomputed live by the findings, and a column that is NULL or stale in most rows invites a
reader to trust it.

One narrow row per limit, not one wide row per sample, so a new kind of limit needs no schema change. At
one sample an hour and a few hundred sequences that is a few thousand rows a day; the primary key
serves every read the projection makes (one series, newest first).

**What `position` and `limit_value` are, per kind.**

| kind | position | limit_value | sampled when |
|---|---|---|---|
| `sequence` | calls of `nextval()` used, in steps of the increment, the quantity 0.1 counts (rate.md) | calls in its whole range | at least `limit_runway.sample_min_used` used (default 10%), **or already in the table** |
| `foreign key` | the parent sequence's position as a value | the child column's maximum | the same threshold and the same exception |
| `xid` | `age(datfrozenxid)`, per database | 2147483648 | always: one row per database |
| `multixact` | `mxid_age(datminmxid)`, per database | 2147483648 | always |
| `replication slot` | WAL retained | retained plus `safe_wal_size` | only with `max_slot_wal_keep_size` set; unset, the limit is the disk and there is nothing to project to |

Connections are not sampled in 0.2 (answer 3), and passwords and partitions are not sampled because
their date is fixed. Per-table XID ages are not sampled: the database's age is the one that stops the
server, and a table row in the view gets no projection.

## The sample

`limit_runway_sample()` reads the same catalogs 0.1 reads, and writes. Rules carried over or added:

- **Cheap, measured.** No table scan, ever: the only reads of table data are 0.1's index end-point and
  one index lookup per owned sequence. Budget to measure before 0.2 ships: a sample on a database with
  10,000 sequences, timed, and the plan of each kind's query captured, as pg_lock_tree's
  `docs/history.md` does for its sampler.
- **Consumes nothing it measures.** The current xid is read with `pg_snapshot_xmax(pg_current_snapshot())`
  (s5); the function must not call `pg_current_xact_id()`, and the INSERT itself does take an xid, once
  per sample, which is negligible and stated.
- **The caller's rights** (answer 1), like every function in the family. The scheduling role needs
  `INSERT` and `SELECT` on `limit_runway_history` on top of 0.1's grants. Without `INSERT` the sampler
  refuses with an error naming the grant; it never writes part of a sample. A sequence the role cannot
  read is **not sampled and counted as not established** in what the sampler returns, never recorded
  as anything, so a series is never pulled down by a role that saw less.
- **What it returns:** one row per kind, how many limits were sampled, how many were below the
  threshold, and how many could not be read, so a scheduled job's log says what it did.
- **Scheduling** is the deployment's: `pg_cron` if present (one line in INSTALL.md, hourly, answer 2),
  or any external scheduler running `SELECT * FROM limit_runway_sample()`. A sequence that runs out in
  hours needs a faster cadence, and the finding says how many samples, over what span, its rate is
  from.
- **The threshold, and its exception** (answer 4): a sequence is first sampled once it is
  `limit_runway.sample_min_used` used (a setting, default `0.10`). Once it has a row it is sampled
  every time, even if it falls back below the threshold (a `setval`, a restore), so a series never
  loses its start and a reset is seen as a reset.

## Breaks in a series

A rate across a discontinuity is nonsense, so the sampler detects one and bumps `epoch`; the
projection uses only the current epoch, and says so when that is not the first: "rate from N samples
since <instant>, when the series restarted". The rule is uniform: **a new epoch whenever the position
falls or the limit changes** from the previous sample of the same key. The cases:

- **A sequence that moved backwards** without cycling: `setval`, `ALTER SEQUENCE RESTART`, a restore.
- **A cycling sequence that wrapped**: its position fell. The wrap is the event the finding is about,
  so the epoch bumps and the state at that sample ("cycled into existing keys", or not if the old keys
  were freed) is what is reported.
- **A limit that changed**: `ALTER SEQUENCE ... MAXVALUE`, a column widened to `bigint` (the fix!), a
  changed setting. The limit is recorded per row, so the projection always uses the newest one, and a
  widening is reported as the finding clearing, not as a rate collapsing.
- **XID age falling**, after a vacuum froze the table: the age is what it is, but the rate since then
  starts from the fall, which is exactly what a new epoch gives.
- **A gap in sampling** (the scheduler stopped): not a break, but the finding says the newest sample
  is old when it is more than three times the series' average interval old, rather than projecting
  from it as if current.

## The projection

From rate.md, unchanged: two samples in the current epoch at least, **spanning real movement**; the
slope over the last 7 days beside the slope over the last 24 hours, each from the oldest sample in
its window to the newest, where a window reaches 10% past its length so that a scheduler's hourly tick
landing a little after the boundary does not cost the series its anchor. The date is computed from the
**newest** sample, its position and limit, as `newest + (limit - position) / rate`, and:

- **if the two slopes differ by more than a factor of two**, the finding gives both dates rather than
  choosing, and the row is ranked by the sooner one, since the ranking has to put it somewhere and
  sooner is the safe side;
- **fewer than two samples** in the current epoch: "no rate yet", as in 0.1;

- **an error band the tool cannot narrow**, because a sequence's rate counts attempts, and failed
  inserts consume values (s1): the text says "at the current rate of consumption, including failed
  inserts";
- **two or more samples with no movement**: "not moving", and no date, not a date in the year 3000. A
  falling position starts a new epoch, so a negative rate cannot occur within one;
- **a date only for limits with a rate.** Partitions and passwords keep their fixed dates. Connections
  stay "current, not a peak" (answer 3): an hourly sample does not see a five-minute storm, so a peak
  from samples would understate the very thing it reports. A finer source is a later item.
- **the ranking changes as ranking.md planned**: class 2, dated, includes projected dates on one
  timeline with the fixed ones; "no rate yet" and "not moving" stay in class 3. A state that is failing
  now (exhausted, behind the data, cycled) is never projected over: it stays class 1.
- **a projected date can bring a row in.** 0.1 lists a sequence only from `min_used` (half) used. A
  sequence at 20% that the samples say runs out within `date_window` is listed too, in class 2, because
  a date is a better reason to list something than a share.
- **a reader who cannot read the history** gets 0.1's findings and one "not established" note that
  rates need `SELECT` on `limit_runway_history`, rather than every row quietly saying "no rate yet".

## Pruning

`limit_runway_prune()` deletes rows older than `older_than`, default 35 days (answer 2: the 7-day slope
needs a week and a month of history explains a date), in **one statement**, not in batches as an
earlier draft said. A function cannot commit between batches, so batching inside one buys nothing;
pg_lock_tree learned that and made its batched prune a procedure. At an hourly sample of a few hundred
limits, 35 days is a few hundred thousand narrow rows, and an index on `sampled_at` bounds the delete.

## What it does not do

- It does not watch columns with no sequence (application-generated keys): there is nothing cheap to
  sample, and `max(id)` without a leading index is a scan. They are named by
  `limit_runway_unwatched()` instead of being skipped silently; a not-watched key has no current value
  and no limit, so it is not a finding.
- It does not alert. Alerting on a window ("within 30 days", then halving) is step 6, under the shared
  contract, and reads the same projection.
- It does not fan out across databases: sequences and partitions are per database (README, open
  questions).

## Decided, 2026-10-11

Piotr answered the four open questions with "defaults":

1. **The sampler runs with the caller's rights**, not as definer. Without the grants it says what it
   could not read ("not established"), and never records a low count.
2. **Hourly** is the documented cadence, and **35 days** is kept, `limit_runway_prune()`'s default.
3. **No connection peaks in 0.2.** Connections stay current state only; a finer source is a later item.
4. **Sequences are sampled from 10% used** (`limit_runway.sample_min_used`), and a key already in the
   table is always sampled, so a series never loses its start.
