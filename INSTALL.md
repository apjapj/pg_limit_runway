# Installing pg_limit_runway

**For: whoever installs it and whoever grants a monitoring role access to it.**

## Requirements

| | |
|---|---|
| PostgreSQL | **14 or later.** On 13 and earlier `CREATE EXTENSION` refuses, and says why. 14 reaches upstream end of life on 2026-11-12 and stays supported until PostgreSQL 19 is stable. Tested on 14 and 18. Newer features degrade per feature: `reserved_connections` exists on 16 and later, and on 14 and 15 the connection limit counts `superuser_reserved_connections` alone and says so. |
| Preloaded libraries | None. Pure SQL, no restart. |
| Privileges to install | A superuser, for `CREATE EXTENSION`. |

## Install

```bash
git clone https://github.com/apjapj/pg_limit_runway.git
cd pg_limit_runway
sudo make install            # copies the control file and pg_limit_runway--0.1.sql
```

```sql
CREATE EXTENSION pg_limit_runway;
SELECT * FROM limit_runway_text();
```

Sequences, foreign keys and partitions are read in the database it is installed in; transaction ids,
slots, connections and passwords are cluster-wide and appear in every database it is installed in.

## Grants for a monitoring role

Nothing is open by default: the view has no grant and the two functions are not executable by PUBLIC,
the same convention as pg_lock_tree and pg_bloat_cause. The minimum is:

```sql
GRANT SELECT ON limit_runway TO monitoring;
GRANT EXECUTE ON FUNCTION limit_runway_findings(numeric, interval),
                          limit_runway_text(numeric, interval) TO monitoring;
GRANT pg_read_all_stats TO monitoring;       -- connection counts (pg_monitor includes it)
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
| `SELECT ON limit_runway` and `EXECUTE` on both functions | PostgreSQL checks a function called inside a view against the role *using* the view, so `SELECT` alone still fails on `limit_runway_findings()` | refused: `permission denied` |
| `pg_read_all_stats` | to see which sessions are client connections, and whose. Measured on 14 and 18: without it a role sees other sessions with their type, user and database hidden, and would count 0 connections of N | one row, connections "not established", and no counts |
| `SELECT` on sequences | reading a sequence's position (its `last_value` and `is_called`) needs it | one row naming the sequences it cannot read, "not established" |
| `SELECT` on tables, and `USAGE` on their schema | whether a sequence is behind its data is read from the column's index, and whether a DEFAULT partition holds rows from the partition: both are reads of the table | one row naming those columns, and a note on the partition, "not established" |
| superuser, or `EXECUTE ON FUNCTION pg_ls_dir(text)` | to count MultiXact member segment files | member space "not established". With it, still "not established" in 0.1, which counts the files but does not compute the limit, so the grant is not worth making for 0.1 |

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

- **Never writes.** No function is VOLATILE. It names fixes (`SELECT setval(...)` for a sequence behind
  its data) as text to run by hand, and never runs them.
- **Never waits.** The functions run with `lock_timeout = 1s`; a table or sequence it cannot lock in time becomes
  "not established" rather than a stalled monitor.
- **Never scans a table.** The reads of table data per sequence are the end entry of an index whose
  leading column is the sequence's column (`ORDER BY col DESC LIMIT 1`, or `ASC` for a descending
  sequence) and one lookup of the next value in that index. With no such index, behind-the-data is "not
  established". The DEFAULT partition check stops at the first row.
- **No history in 0.1**, so no rate and no projected dates: "no rate yet" is a state, ordered by the share
  of the limit used. The only dates are fixed ones: a password's expiry and a partition's last bound.

## Uninstall

```sql
DROP EXTENSION pg_limit_runway;
```

Nothing is left behind: 0.1 has no tables.
