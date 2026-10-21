# Installing pg_limit_runway

**For: whoever installs it and whoever grants a monitoring role access to it.**

## Requirements

| | |
|---|---|
| PostgreSQL | **14 or later.** On 13 and earlier `CREATE EXTENSION` refuses, and says why. 14 reaches upstream end of life on 2026-11-12 and stays supported until PostgreSQL 19 is stable. Tested on 14 to 19, where 19 is the current pre-release (`19beta4`). Newer features degrade per feature: `reserved_connections` exists on 16 and later, and on 14 and 15 the connection limit counts `superuser_reserved_connections` alone and says so. |
| Preloaded libraries | None. Pure SQL, no restart. |
| Privileges to install | A superuser, for `CREATE EXTENSION`. |

## Install

```bash
git clone https://github.com/apjapj/pg_limit_runway.git
cd pg_limit_runway
sudo make install            # copies the control file and every release and update script
```

```sql
CREATE EXTENSION pg_limit_runway;
SELECT * FROM limit_runway_text();
```

Sequences, foreign keys and partitions are read in the database it is installed in; transaction ids,
slots, connections and passwords are cluster-wide and appear in every database it is installed in.

From 0.1: `ALTER EXTENSION pg_limit_runway UPDATE TO '0.2';`. It adds the history and replaces
`limit_runway_findings()` in place, so the grants below survive it.

From 0.3.0: `ALTER EXTENSION pg_limit_runway UPDATE TO '0.4.0';`. It adds `limit_runway_command()` and
the `from_date` column on the findings. A `RETURNS TABLE` function's row type cannot be changed in
place, so this update drops and recreates `limit_runway_findings()`, and with it the `limit_runway` view
and `limit_runway_text()`, which depend on it. Dropping them drops their grants: re-issue
`GRANT SELECT ON limit_runway` and `GRANT EXECUTE ON FUNCTION limit_runway_text(...)` (and on
`limit_runway_command(...)` if you want it) after updating. The next section lists them.

From 0.4.0: `ALTER EXTENSION pg_limit_runway UPDATE TO '0.4.1';`. It changes one function body
(`limit_runway_command_row()`, a quoting fix) with `CREATE OR REPLACE`, so nothing is dropped and no
grant is affected: the re-grant above is only for the 0.3.0 step. An installation at 0.3.0 updates
through each step in order, and `ALTER EXTENSION pg_limit_runway UPDATE` with no `TO` runs the whole
chain.

From 0.4.1: `ALTER EXTENSION pg_limit_runway UPDATE TO '0.5.0';`. It adds `level` and
`previous_level` to the `alerting` payload and sends an escalation as `alerting` rather than the
reserved `escalated`; both functions change with `CREATE OR REPLACE`, so nothing is dropped and no
grant is affected.

From 0.5.0: `ALTER EXTENSION pg_limit_runway UPDATE TO '0.5.1';`. It makes
`limit_runway_sequences()` require `USAGE` on a sequence's schema as well as `SELECT` on the
sequence, so a sequence the caller cannot reach, such as `cron.jobid_seq`, is reported unreadable
instead of raising. One `CREATE OR REPLACE`; no grant is affected.

From 0.5.1: `ALTER EXTENSION pg_limit_runway UPDATE TO '0.5.2';`. It reads composite foreign
keys, one column pair at a time, so a multi-column key's `int4` child column against a `bigint`
parent is reported rather than skipped. Two `CREATE OR REPLACE` bodies; no grant is affected.

From 0.5.2: `ALTER EXTENSION pg_limit_runway UPDATE TO '0.6.0';`. It adds
`limit_runway_unwatched()`, which names the integer primary-key and unique-index columns with no
sequence, instead of skipping them. One `CREATE FUNCTION`; no existing object or grant changes. The
function is closed to `PUBLIC`; grant `EXECUTE` to the role that should see the list.

From 0.6.0: `ALTER EXTENSION pg_limit_runway UPDATE TO '0.7.0';`. It adds
`limit_runway_rate()`, which exposes the 7-day and 24-hour slopes, their disagreement and the date
the finding uses. One `CREATE FUNCTION`; no existing row type or grant changes.

## Sampling, for dates (0.2)

A projected date needs samples. Schedule the sampler hourly, as a role with the grants in the next
section plus the two on the history:

```sql
GRANT SELECT, INSERT ON limit_runway_history TO sampler;
GRANT EXECUTE ON FUNCTION limit_runway_sample(timestamptz) TO sampler;
GRANT EXECUTE ON FUNCTION limit_runway_prune(interval)     TO sampler;   -- and DELETE, below
GRANT DELETE ON limit_runway_history TO sampler;

-- with pg_cron, in the database the extension is installed in:
SELECT cron.schedule('limit_runway_sample', '0 * * * *', 'SELECT * FROM limit_runway_sample()');
SELECT cron.schedule('limit_runway_prune',  '30 3 * * *', 'SELECT limit_runway_prune()');
```

`limit_runway_prune()` keeps 35 days by default: a week for the slope and a month to explain a date.
Sequences are sampled from 10% used; `SET limit_runway.sample_min_used = 0.05` (or in the role's or
database's settings) changes that, and a sequence already sampled is always sampled again, so its
series never loses its start.

The sampler runs with its caller's rights. Without `SELECT` and `INSERT` on the history it refuses and
names the grant. A sequence the role cannot read is not recorded at all and is counted as not
established in what it returns, so a series is never pulled down by a role that saw less. A reader
needs `SELECT` on the history to see rates; without it the view says rates are not established.

## Grants for a monitoring role

Nothing is open by default: the view has no grant and the two functions are not executable by PUBLIC,
the same convention as pg_lock_tree and pg_bloat_cause. The minimum is:

```sql
GRANT SELECT ON limit_runway TO monitoring;
GRANT EXECUTE ON FUNCTION limit_runway_findings(numeric, interval),
                          limit_runway_text(numeric, interval) TO monitoring;
-- to run the statements the Act stage returns (paste them, or SELECT command ... \gexec):
GRANT EXECUTE ON FUNCTION limit_runway_command(numeric) TO monitoring;
GRANT pg_read_all_stats TO monitoring;       -- connection counts (pg_monitor includes it)
GRANT SELECT ON limit_runway_history TO monitoring;   -- rates and projected dates (0.2)
```

and, for sequences and partitions, one of:

```sql
GRANT pg_read_all_data TO monitoring;        -- every table and sequence, read-only
-- or, narrower, per schema:
GRANT USAGE ON SCHEMA app TO monitoring;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA app TO monitoring;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO monitoring;
```

What each one is for, and what the role gets without it:

| Grant | Why | Without it |
|---|---|---|
| `SELECT ON limit_runway` and `EXECUTE` on the readers (and `EXECUTE` on `limit_runway_command()` to run the statements) | PostgreSQL checks a function called inside a view against the role *using* the view, so `SELECT` alone still fails on `limit_runway_findings()` | refused: `permission denied` |
| `pg_read_all_stats` | to see which sessions are client connections, and whose. Measured on 14 and 18: without it a role sees other sessions with their type, user and database hidden, and would count 0 connections of N | one row, connections "not established", and no counts |
| `SELECT ON limit_runway_history` (0.2) | rates and projected dates are fitted to the samples | one row, rates "not established", and 0.1's findings otherwise |
| `SELECT` on sequences | reading a sequence's position (its `last_value` and `is_called`) needs it | one row naming the sequences it cannot read, "not established" |
| `SELECT` on tables, and `USAGE` on their schema | whether a sequence is behind its data is read from the column's index, and whether a DEFAULT partition holds rows from the partition: both are reads of the table | one row naming those columns, and a note on the partition, "not established" |
| superuser, or `EXECUTE ON FUNCTION pg_ls_dir(text)` | to count MultiXact member segment files | member space "not established". With it, still "not established" in 0.1, which counts the files but does not compute the limit, so the grant is not worth making for 0.1 |

**Three helpers are open.** `limit_runway_sequences()`, `limit_runway_projection()` and
`limit_runway_project()` keep the default `EXECUTE` for `PUBLIC`: `limit_runway_findings()` calls them
with its caller's rights, so a role granted the readers must be able to call them, and an update from
0.1 must not take that away. They show nothing beyond the caller's own privileges: a sequence it cannot
read comes back with no figures, and the history is behind its own `SELECT` grant. `limit_runway_command()`
is closed like the readers, and its internal per-row derivation, `limit_runway_command_row()`, is closed
too: it is not a helper a caller needs, only the seam the per-kind test uses.

**Why not SECURITY DEFINER.** The functions only read. As definer they would show every sequence and
every session to any role granted EXECUTE, bypassing the privileges above, and the notes telling a role
what it cannot see could never fire. So they run with the caller's rights and say what those rights hide.

`test/01_limit_runway.sql` asserts this as real roles: a role with no grants is refused; a role with the
grants and `pg_monitor` but no table access reads the view and gets the not-established rows for member
space and the tables it cannot read; a role with the grants but without `pg_read_all_stats` gets
connections "not established" and no counts.

Nothing else is needed. `pg_class`, `pg_sequence`, `pg_partitioned_table`, `pg_database`, `pg_roles` and
`pg_replication_slots` are readable by any role.

## What it reads, and what it never does

- **Reading never writes.** Only `limit_runway_sample()` and `limit_runway_prune()` are VOLATILE, and
  they write only `limit_runway_history`. The readers name fixes (`SELECT setval(...)` for a sequence
  behind its data) as text to run by hand, and never run them.
- **Never waits.** The functions run with `lock_timeout = 1s`; a table or sequence it cannot lock in time becomes
  "not established" rather than a stalled monitor.
- **Never scans a table.** The reads of table data per sequence are the end entry of an index whose
  leading column is the sequence's column (`ORDER BY col DESC LIMIT 1`, or `ASC` for a descending
  sequence) and one lookup of the next value in that index. With no such index, behind-the-data is "not
  established". The DEFAULT partition check stops at the first row.
- **A date only from samples.** Without two samples in one unbroken series that moved, a limit is "no
  rate yet" or "not moving", ordered by the share used. A sample consumes one transaction id, the
  INSERT's, and reads no table: measured over 10,000 sequences in s19, in about a second.

## Uninstall

```sql
DROP EXTENSION pg_limit_runway;
```

It drops `limit_runway_history` and its samples with it. They are registered with `pg_dump`, so a dump
taken before keeps them.
