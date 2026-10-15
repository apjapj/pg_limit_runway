# act: the one statement per limit, and why it is that one

**Status: not implemented.** This is the plan for `limit_runway_command()`, written before the SQL, the
way `pg_bloat_cause` planned its measurement function before writing it. `docs/command.md` is the
authority for the function's shape and its three tiers; this document is the authority for what goes
in the `command` and `note` columns, one row per limit kind.

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
| `xid`, per table | `VACUUM (FREEZE) <tbl>` | freezes only rows past `vacuum_freeze_min_age`; it need not lower the age if the old rows are not yet eligible |
| `xid`, per database | `VACUUM (FREEZE)` | every table in the database; the least destructive step that lowers the age, and it is not cheap |
| `multixact`, per database | `VACUUM (FREEZE)` | as the xid case. The member-space limit is not established, so it has no command |
| `partition` | **open, see below** | |
| `replication slot` | `SELECT pg_drop_replication_slot('<slot>')` | the consumer must be rebuilt from a fresh base backup; the slot is already invalidated or about to be |
| `connections` | `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE backend_type = 'client backend' AND state = 'idle' AND pid <> pg_backend_pid()` | frees idle client connections only; superusers are exempt from the limit, and busy sessions are left alone |
| `password` | `ALTER ROLE <role> VALID UNTIL '<date>'` | a new expiry date, never a password; a role whose logins do not use a password is unaffected |

A finding whose state is `not established` has no command and is not returned: a gap is not something
to act on. That is the same decision `docs/command.md` records for alerting, applied to acting.

## The shape the object column has, and how the command is built

`object` is the same qualified name `limit_runway_findings()` prints, so the command is a `format()`
over it, not a second lookup. The sequence kind is the one that needs care: the object is the
**column** when a column fills the sequence (three dotted parts) and the **sequence** when none does
(two). The command branches on that, which is why the row is built from the finding and not from the
catalog again.

## The one open question: partitions, now decided

Every other kind carries enough in its finding to build a complete statement. A partition does not.
The finding gives the **last partition's upper bound** (`until_date`) and nothing about the width:

```
CREATE TABLE <table>_<next> PARTITION OF <table> FOR VALUES FROM ('<last_bound>') TO ('<next_bound>')
```

The `FROM` is known and the table name can be derived, but the `TO` is `last_bound + one interval`,
and the interval is whatever the existing partitions use, which the finding does not say.

**Decided: the partition finding grows by one OUT column, the last partition's lower bound.** The
width is then `last_bound - lower_bound`, both bounds are exact, and the command is complete and
runnable. The alternatives, a placeholder or no command at all, were rejected: the first breaks the
"runnable or not there at all" rule and the second loses the thing the tool is for.

The cost is larger than this document first claimed, and the correction is worth stating. This
function's row type is part of its signature, so the column **cannot** be added with `CREATE OR
REPLACE`: it is `DROP FUNCTION` then `CREATE`, exactly as `pg_bloat_cause`'s 0.2.2 had to do for
`limit_runway_sequences()`. And `limit_runway` is `SELECT * FROM limit_runway_findings()`, so the
view gains the column too, and the view's column check in `test/01_limit_runway.sql` moves by one.
Grants on the function must be restated, because a dropped function takes its grants with it. The
two existing readers that matter, `limit_runway_text()` and the view, use named columns and are
unaffected by the addition itself.

## What must not change

- The command runs nothing. It returns text.
- The two readers that matter, `limit_runway_text()` and the `limit_runway` view, keep working. The
  view gains the partition lower bound, and that is the one visible change; it is additive to every
  column that existed before.
- Version: this is a new release, a new release script and an update path, never an edit to the
  released `0.3.0`. The `DROP FUNCTION`/`CREATE` of the findings function is why the update path is
  not a plain `CREATE OR REPLACE` and has to restate the grants.

## The next concrete step

The partition question is settled above. Write the pgTAP test asserting the **tier and the command
for one fixture of each kind**, against the function absent so it fails loudly, then add the lower
bound to the finding and `limit_runway_command()` to make it pass. One scenario per kind that can be
built cheaply, asserting the statement is a single statement and names the right object.
