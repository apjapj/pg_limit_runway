# act: the one statement per limit, and why it is that one

**Status: implemented in 0.4.0, with 0.4.1 fixing how the command quotes a name.** This is the plan for
`limit_runway_command()` that was written before the SQL, the way `pg_bloat_cause` planned its
measurement function before writing it, and the SQL followed it. `docs/command.md` is the authority
for the function's shape and its three tiers; this document is the authority for what goes in the
`command` and `note` columns, one row per limit kind.

## What it is

`limit_runway_command(min_used)` returns one row per finding the view reports as needing action, with
the **least destructive statement that can work**, for pasting or for
`SELECT command FROM limit_runway_command() \gexec`. It runs nothing itself.

Two rules decide every statement:

1. **Runnable, or not there at all.** The statement is complete: names are qualified, and there is no
   placeholder for the caller to fill in. A statement that needs editing before it runs is a note, not
   a command.
2. **Least destructive.** Where a limit can be raised or cleared more than one way, the statement is
   the one that touches the least: widen a column and pay a rewrite, rather than drop and rebuild;
   freeze the tables that are old rather than the whole cluster; drop the slot that is already useless
   rather than keep paying for it.

The `tier` column (`plan`, `schedule`, `act`) comes from `docs/command.md`. The `note` is the cost or
the caveat, in the same spirit as `pg_lock_tree`'s `lock_tree_command()`: it says what the statement
will do to the server, because "the least destructive" is not "free".

## The statements, one per kind

| kind | the command | the note |
|---|---|---|
| `sequence`, a column fills it | `ALTER TABLE <tbl> ALTER COLUMN <col> TYPE bigint` | rewrites the whole table under `ACCESS EXCLUSIVE`; the only step that raises the column's limit |
| `sequence`, no column owns it | `ALTER SEQUENCE <seq> AS bigint` | raises the sequence's own ceiling; if a column fills it, that column is the real limit and must widen too |
| `foreign key` | `ALTER TABLE <child> ALTER COLUMN <col> TYPE bigint` | rewrites the child table under `ACCESS EXCLUSIVE`; the parent key is already wide |
| `xid`, per table | `VACUUM (FREEZE) <tbl>` | freezes only rows past `vacuum_freeze_min_age`; it need not lower the age if the old rows are not yet eligible. `VACUUM` needs no transaction block |
| `xid`, per database | `VACUUM (FREEZE)` | every table in the database; the least destructive step that lowers the age, and it is not cheap. `VACUUM` needs no transaction block |
| `multixact`, per database | `VACUUM (FREEZE)` | as the xid case, and it too needs no transaction block. The member-space limit is not established, so it has no command |
| `partition` | **open, see below** | |
| `replication slot` | `SELECT pg_drop_replication_slot('<slot>')` | the consumer must be rebuilt from a fresh base backup; the slot is already invalidated or about to be |
| `connections` | `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = 'client backend' AND state = 'idle' AND pid <> pg_backend_pid()` | frees idle client connections only; superusers are exempt from the limit, and busy sessions are left alone |
| `password` | `ALTER ROLE <role> VALID UNTIL '<now + 1 year>'` | a new expiry date, never a password; a role whose logins do not use a password is unaffected |

A finding whose state is `not established` has no command and is not returned: a gap is not something
to act on. That is the same decision `docs/command.md` records for alerting, applied to acting.

One value the finding cannot supply is the new password expiry, and rule 1 will not let the command
leave it to the operator to fill in. The command sets it one year ahead of `now()`, a concrete runnable
date: the least destructive step that clears the finding, while the policy of how far to renew stays
the operator's to change by editing the row they paste.

## The shape the object column has, and how the command is built

`object` is the same qualified name `limit_runway_findings()` prints, so the command is a `format()`
over it, not a second lookup. That name is **already quoted**, because the finder builds it with `%I`,
so the derivation recovers the parts with `parse_ident()` and quotes each exactly once: `%I` applied to
a part that is already `"Mixed"` would produce `"""Mixed"""`, naming an object that does not exist.
`parse_ident()` also splits a dot inside a quoted name correctly, which a `string_to_array()` on `'.'`
does not. The sequence kind is the one that needs care: the object is the **column** when a column
fills the sequence (three parts) and the **sequence** when none does (two). The command branches on
that, which is why the row is built from the finding and not from the catalog again. A partition's new
name is the last bound's date suffix inside one `%I`, so a mixed-case parent becomes
`"Events Tbl_20260301"` and not `"Events Tbl"_20260301`.

## The one open question: partitions, now decided

Every other kind carries enough in its finding to build a complete statement. A partition does not.
The finding gives the **last partition's upper bound** (`until_date`) and nothing about the width:

```
CREATE TABLE <table>_<next> PARTITION OF <table> FOR VALUES FROM ('<last_bound>') TO ('<next_bound>')
```

The `FROM` is known and the table name can be derived, but the `TO` is `last_bound + one interval`,
and the interval is whatever the existing partitions use, which the finding does not say.

**Decided: the partition finding grows by one OUT column, the last partition's lower bound, called
`from_date`.** It pairs with the existing `until_date`, that partition's upper bound. The width is then
`until_date - from_date`, both bounds are exact, and the command is complete and runnable:
`CREATE TABLE <schema>.<table>_<YYYYMMDD> PARTITION OF <schema>.<table> FOR VALUES FROM
('<until_date>') TO ('<until_date + width>')`. The new partition's name is derived from its lower
bound's date, because the finding carries no name for the last partition. The alternatives, a
placeholder or no command at all, were rejected: the first breaks the "runnable or not there at all"
rule and the second loses the thing the tool is for. A partition whose lower bound is `MINVALUE` has no
quoted bound to read, so it yields no command either, for the same first rule.

The width is one interval of **days**, because the finding carries two bounds and nothing else, so a
monthly partition calendar drifts. A February partition is 28 days wide, so the next one ends on
29 March and is named for 1 March; the bound after it is 26 April, and each step moves further off a
month boundary while the ranges stay contiguous. That is a naming and operations consequence, not a
correctness one: partition pruning reads the bounds, not the names, and a range is never left
uncovered. Trading a day-count walk for a calendar one would need the finding to carry the partition's
granularity, and a month-start pair is not distinguishable from a week that happens to start on the
first; the tool does not guess. The `note` says the width is "the same as the last one's", which is
exactly what the statement does. The new partition's name carries the lower bound's date as
`to_char()` renders it in the session's `TimeZone`, so an operator whose session is not UTC can see
a name a day off the bound; the bounds are what pruning reads, so this is a naming consequence like
the width drift, not a correctness one.

The cost is larger than this document first claimed, and the correction is worth stating. This
function's row type is part of its signature, so the column **cannot** be added with `CREATE OR
REPLACE`: it is `DROP FUNCTION` then `CREATE`, exactly as `pg_bloat_cause`'s 0.2.2 had to do for
`limit_runway_sequences()`. And `limit_runway` is `SELECT * FROM limit_runway_findings()`, so the
view gains the column too, and the view's column check in `test/01_limit_runway.sql` moves by one.
`limit_runway_text()` is a SQL function whose stored query depends on `limit_runway_findings()`, so it
is dropped and recreated with it, and so is the view. Dropping them drops their grants: the update path
restates the extension's own `REVOKE ... FROM PUBLIC`, and a monitoring role that had `SELECT ON
limit_runway` or `EXECUTE` on `limit_runway_text()` must be granted again, which the changelog and
`INSTALL.md` say. The readers' definitions are otherwise unaffected: they use named columns, so the
added `from_date` changes nothing they select.

## What must not change

- The command runs nothing. It returns text.
- The two readers that matter, `limit_runway_text()` and the `limit_runway` view, keep working. The
  view gains the partition lower bound, and that is the one visible change to them; it is additive to
  every column that existed before, and the new `limit_runway_command()` is a separate object.
- Version: this is a new release, a new release script and an update path, never an edit to the
  released `0.3.0`. The `DROP FUNCTION`/`CREATE` of the findings function is why the update path is
  not a plain `CREATE OR REPLACE` and has to restate the grants.

## What was built, and how it was checked

The partition question settled above was built exactly that way, in 0.4.0. `test/04_command.sql` was
written against the function absent, so it failed loudly, and it asserts the **tier and the command for
one fixture of each kind**. The kinds a single pgTAP transaction cannot build (an xid age, a MultiXact
age, a lost replication slot) are asserted through `limit_runway_command_row()`, the internal per-row
derivation, with a synthetic finding; the public `limit_runway_command()` is asserted against the
sequence, foreign-key, partition, password and connection fixtures the transaction can build, so the
finding and the statement are checked end to end. Every returned statement is asserted to be one
non-empty, terminated statement, and, where a fixture builds the finding, to be exactly the statement
that finding implies; the command list is asserted to be exactly
the findings that are not "not established", so the two cannot drift. 0.4.1 is the repair of one fault
those fixtures did not see: every object in `test/04` was a lowercase name, so a name that needed
quoting was never built. It now has a quoted schema and one quoted fixture of each kind, the internal
derivation is asserted with an already-quoted object, and the statement is what `psql` runs.
