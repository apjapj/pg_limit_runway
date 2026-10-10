# history: the sample, the table and the projection (README step 5), a design to review

**For: whoever builds 0.2, and Piotr, who decides the open questions at the end.** Nothing here is
built. It turns [rate.md](rate.md)'s rules into objects, and every rule it relies on is stated there
with its evidence; this page says how 0.2 would implement them, what it would cost, and what it would
still not know.

## What 0.2 adds

| Object | What it is |
|---|---|
| `limit_runway_history` | one row per limit per sample: when, what, the value, the limit |
| `limit_runway_sample()` | reads every limit once and appends to the history. The only writer, and the only thing to schedule |
| `limit_runway_prune(older_than interval)` | deletes samples older than the window, in batches |
| `limit_runway_findings()`, the view and `limit_runway_text()` | gain a rate, a 24-hour rate beside it, and a projected date, where two samples allow one |

## The table

```sql
CREATE TABLE limit_runway_history (
  sampled_at   timestamptz NOT NULL,
  kind         text        NOT NULL,   -- 'sequence', 'xid', 'multixact', 'slot', 'connections', ...
  object       text        NOT NULL,   -- as in the view: schema.table.column, database name, slot name
  position     numeric,                -- the quantity that moves: calls used, xid age, WAL retained, connections in use
  limit_value  numeric,                -- the limit at the time, since it can change (ALTER SEQUENCE, a setting)
  state        text,                   -- the 0.1 state at the time: 'no rate yet', 'exhausted', 'behind the data', ...
  epoch        int         NOT NULL DEFAULT 0,   -- bumped when the series is broken (below)
  PRIMARY KEY (kind, object, sampled_at)
);
```

One narrow row per limit, not one wide row per sample, so a new kind of limit needs no schema change. At
one sample an hour and a few hundred sequences that is a few thousand rows a day; the primary key
serves every read the projection makes (one series, newest first).

**What `position` is, per kind.** For a sequence, calls of `nextval()` used so far in steps of the
increment, the quantity 0.1 now counts (rate.md), so a rate is calls per day and the projection divides
calls left by it. For XID and MultiXact, the age. For a slot with `max_slot_wal_keep_size` set, the
WAL retained; unset, the same figure is recorded, and the finding stays "the limit is the disk".
Connections: the count at the sample. Passwords and partitions are not sampled: their date is fixed.

## The sample

`limit_runway_sample()` reads the same catalogs 0.1 reads, and writes. Rules carried over or added:

- **Cheap, measured.** No table scan, ever: the only reads of table data are 0.1's index end-point and
  one index lookup per owned sequence. Budget to measure before 0.2 ships: a sample on a database with
  10,000 sequences, timed, and the plan of each kind's query captured, as pg_lock_tree's
  `docs/history.md` does for its sampler.
- **Consumes nothing it measures.** The current xid is read with `pg_snapshot_xmax(pg_current_snapshot())`
  (s5); the function must not call `pg_current_xact_id()`, and the INSERT itself does take an xid, once
  per sample, which is negligible and stated.
- **`SECURITY DEFINER`, like `lock_tree_sample()`, or not?** It must write the table, which is the case
  pg_lock_tree made definer for. But a definer sampler sees every sequence and session, so the history
  would hold what the scheduling role cannot read directly. Proposed: definer with `search_path` pinned
  to `pg_catalog`, `REVOKE ... FROM PUBLIC`, and the history table readable only through the view,
  whose findings already run with the reader's rights. Open question 1.
- **Scheduling** is the deployment's: `pg_cron` if present (one line in INSTALL.md), or any external
  scheduler running `SELECT limit_runway_sample()`. Proposed default cadence: hourly. A sequence that
  runs out in hours needs a faster one, and the finding says what cadence it was measured at.

## Breaks in a series

A rate across a discontinuity is nonsense, so the sampler detects one and bumps `epoch`; the
projection uses only the current epoch.

- **A sequence that moved backwards** without cycling: `setval`, `ALTER SEQUENCE RESTART`, a restore.
- **A cycling sequence that wrapped**: its position fell. The wrap is the event the finding is about,
  so the epoch bumps and the state at that sample ("cycled into existing keys", or not if the old keys
  were freed) is what is reported.
- **A limit that changed**: `ALTER SEQUENCE ... MAXVALUE`, a column widened to `bigint` (the fix!), a
  changed setting. The limit is recorded per row, so the projection always uses the newest one, and a
  widening is reported as the finding clearing, not as a rate collapsing.
- **XID age falling**, after a vacuum froze the table: not a break, the age is what it is, but the
  rate since then starts from the fall.
- **A gap in sampling** (the scheduler stopped): not a break either, but the finding says the newest
  sample is old, rather than projecting from it as if current.

## The projection

From rate.md, unchanged: two samples in the current epoch at least; the slope over the last 7 days
beside the slope over the last 24 hours; if they differ by more than a factor of two, the finding says
so rather than choosing. The date is `now() + left / rate`, computed from the **newest** sample, and:

- **an error band the tool cannot narrow**, because a sequence's rate counts attempts, and failed
  inserts consume values (s1): the text says "at the current rate of consumption, including failed
  inserts";
- **no date when the rate is zero or negative** (a quiet sequence; XID age falling): "not moving", not a
  date in the year 3000;
- **a date only for limits with a rate.** Partitions and passwords keep their fixed dates; connections
  become **the peak over the window**, from the samples, with the caveat that a peak between two
  samples is not seen (an hourly sample does not see a five-minute storm). That caveat is in the text,
  and is why 0.1 says "current, not a peak" today.
- **the ranking changes as ranking.md planned**: class 2, dated, now includes projected dates on one
  timeline with the fixed ones; "no rate yet" is left for limits with fewer than two samples.

## What it does not do

- It does not watch columns with no sequence (application-generated keys): there is nothing cheap to
  sample, and `max(id)` without a leading index is a scan. Such columns are listed as "not watched",
  as the README says, rather than skipped silently.
- It does not alert. Alerting on a window ("within 30 days", then halving) is step 6, under the shared
  contract, and reads the same projection.
- It does not fan out across databases: sequences and partitions are per database (README, open
  questions).

## Open questions for Piotr

1. **Definer sampler** (above): definer, with the history readable only through the reader-rights view,
   or invoker, requiring the scheduling role to hold `pg_read_all_data` and `pg_read_all_stats`?
2. **Default cadence and retention**: hourly, 35 days (enough for the 7-day slope and a month of
   peaks)?
3. **Peak connections**: is an hourly sample's peak worth reporting at all, or should connections stay
   "current" until a cheaper, finer source exists?
4. **Sequences at scale**: one row per sequence per sample, or only sequences past a share used (say
   10%), to keep the table small on schemas with tens of thousands of sequences? The second loses the
   rate of a sequence until it crosses the threshold.
