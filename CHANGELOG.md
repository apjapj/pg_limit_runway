# changelog

Versions are listed newest first. Released tags are never edited: a change that needs
a new entry gets a new version.

## 0.5.1 (2026-10-19)

A patch release for one defect found by the family's works-alongside test.

`limit_runway_sequences()` required `SELECT` on a sequence but not `USAGE` on the sequence's
schema. A role can hold the first without the second; the read then raised "permission denied for
schema", which took the whole function down instead of marking that row unreadable. Reproduced
with `cron.jobid_seq`, which exists once `pg_lock_tree`'s `pg_cron` test has run in the same
database. The function now requires both privileges before it reads.

No signature, returned column or table changes; `CREATE OR REPLACE` in the update path.

## 0.5.0 (2026-10-19)

The two escalation keys of the shared `pg_incident_watch` alert contract, on the event the
contract expects them on.

**Behaviour change: an escalation is now an `alerting` event with `previous_level` set. This
release stops sending `escalated`, which the contract reserves and says no tool sends. A listener
that branched on `escalated` must branch on `previous_level` instead; a listener that ignored
`escalated` sees no change beyond the two new keys.**

- `limit_runway_notify()` sends `event = 'alerting'` for an escalation as well as for an onset,
  and adds `level` and `previous_level`. `level` is the count read after the increment: 1 at
  onset, prior + 1 at each escalation. `previous_level` is null at onset and the previous level
  after that. `escalated` is reserved by the contract and sent by no tool; this release stops
  sending it, and no value is removed from the vocabulary.
- `limit_runway_notify_resolved()` adds `level` to the `cleared` payload: the last level the
  incident reached. `previous_level` is absent there, not present and null.
- No signature, returned column or table changes. Both functions are replaced, so grants and
  comments survive. The update path from 0.4.1 ships.

This matches `pg_lock_tree` 1.2.0 and `pg_bloat_cause` 0.4.0, and completes the family: all
three tools now send the escalation keys on `alerting`.

## 0.4.1 (2026-10-15)

A quoting fix to the Act stage, and the first test that runs an update path.

`limit_runway_command_row()` split the finding's `object` on `.` and then applied `%I` to each part, but
the finder builds that object with `%I` already, so any name that needed quoting came back
double-quoted: `"lr C"."Mixed Table".id` became `"""lr C"""."""Mixed Table""".id`, a statement naming an
object that does not exist, which is the first rule of [docs/act.md](docs/act.md) broken. A lowercase
name was unaffected, which is why every 0.4.0 fixture passed. The derivation now recovers the names
with `parse_ident()`, which also splits a dot inside a quoted name correctly, and quotes each exactly
once; a new partition's name is one quoted identifier with the date suffix inside the quotes, so a
mixed-case parent gives `"Events Tbl_20260301"` and not `"Events Tbl"_20260301`. The `xid` and
`multixact` notes gained one clause: `VACUUM` cannot run inside a transaction block.

- **No re-grant needed.** The function's row type does not change, so this update path is a single
  `CREATE OR REPLACE FUNCTION` body plus its comment and `REVOKE`: no `DROP`, and no grant taken with
  it. 0.4.0's drop-and-recreate of the findings function stays as it is; an installation still at
  0.3.0 runs both update scripts in order and the 0.4.0 re-grant note below still applies to it.
- `test/05_upgrade.sql` is new, and is the first thing in the repository to execute a
  `pg_limit_runway--X--Y.sql` at all: it creates 0.3.0, updates through the chain, and asserts the
  changelog's promises, including that a monitor role's grant is gone until it is re-issued. It drops
  the extension before it creates 0.3.0, so it runs whether or not the server already carries one:
  the Forgejo scenario jobs install 0.4.1 before `pg_prove`, and a bare `CREATE EXTENSION ... VERSION
  '0.3.0'` refused it as already existing, a red run `ci/job.sh` (which does not pre-install) could
  not reproduce.
- `test/04_command.sql` grows a quoted schema and one quoted fixture of each kind the command builds
  by splitting the object, plus an order assertion, a note assertion and a 0.5-set parity assertion.
- The scenario s4 now prints the command the Act stage builds for its foreign key, so the statement
  itself is under the byte-identical evidence check.
- `pg_limit_runway--0.4.0--0.4.1.sql` opens with the `\echo Use "ALTER EXTENSION ..." \quit` guard
  every other release and update script carries, so sourcing it in psql aborts with the instruction
  rather than failing later on `@extschema@`.
- `SECURITY.md`'s supported-versions table had named 0.2.1 as the current release since 0.2.1; it
  now names 0.4.1, and `scripts/lint-docs.sh` checks a "current release" table row against the
  control file's `default_version`.
- Documents that called the tested range "14 and 18" now state the range CI actually runs, 14 to
  18, and `scripts/check-pg-versions.sh` (run by `make lint`) fails if the matrix skips a version
  inside its range, if another workflow runs a version the matrix does not, or if a scenario has no
  committed evidence for a matrix version. Both CI lint jobs now run `make lint`, so a check added
  to the Makefile cannot be missing from CI: two were.
- `CONTRIBUTING.md` records the convention the remaining "measured on 14 and 18" sentences follow: a
  past measurement names the versions it was measured on and is left as written, while a coverage
  claim names the matrix range, 14 to 19. Its own test list also had a stale count, `test/04_command.sql`
  as `plan(42)` against the `plan(43)` it now is.
- `defects/` records the extension's real defects and `make defects` re-injects each one and requires
  the test that caught it to fail, so the 0.4.0 quoting bug cannot come back unnoticed: the record is
  the reverse of the 0.4.1 fix, and `test/04` must fail while it is applied. It reports a regression
  rate, not a one-time check.
- `ci/job.sh` gained a preflight that names a missing docker CLI or an unanswered daemon before the
  build, where that failure was previously "failed to connect to the docker API".
- `scripts/lint-docs.sh` checks the test list now, the way it already checks the scenario count: every
  `test/*.sql` must be named in `CONTRIBUTING.md` and its `plan(N)` must match the file, so the stale
  count above cannot come back.

## 0.4.0 (2026-10-15)

The Act stage: for every finding that needs action, the least destructive statement that can work, with
its tier and its cost. `limit_runway_command()` returns one runnable row per finding, for pasting or for
`SELECT command FROM limit_runway_command() \gexec`; it runs nothing itself. The tier is the coarser
grouping of the same ladder the sender uses: `plan` more than 7 days out, `schedule` 1 to 7, `act` under
a day or failing now. A finding the tool cannot establish is not returned, because a gap is not
something to act on. The statement and the note for each kind are the contract in
[docs/act.md](docs/act.md); the row shape and the three tiers are in [docs/command.md](docs/command.md).

One existing object changes, additively but not in place. A partition finding now carries `from_date`,
the last partition's lower bound, so `limit_runway_command()` can build the next
`CREATE TABLE ... PARTITION OF` with an exact width instead of a placeholder. A `RETURNS TABLE`
function's row type is part of its signature, so the update drops and recreates
`limit_runway_findings()`, and with it the `limit_runway` view and `limit_runway_text()`, which depend
on it.

- **Re-grant after the update.** Dropping the view and `limit_runway_text()` drops their grants too. A
  role that had `GRANT SELECT ON limit_runway` or `GRANT EXECUTE ON FUNCTION limit_runway_text(...)`
  needs them re-issued (INSTALL.md lists the monitoring grants). The extension's own rule, that nothing
  is executable by `PUBLIC`, is restored by the update.
- `limit_runway_command()` is closed by default, like the other readers: grant it to the role that
  should run the statements.
- `limit_runway_findings()` grows one column, `from_date`, and the `limit_runway` view grows it too,
  appended after `unknowns` so every earlier column keeps its place.

Internal: `limit_runway_command_row()` holds the per-finding derivation, so the statement for a kind a
test cannot build inside one transaction (an xid age, a lost replication slot) is still pinned with a
synthetic row. It is `REVOKE`d from `PUBLIC`.

## 0.3.0 (2026-10-15)

The Detect stage: it tells you before a limit is reached, and it stops telling you when there is
nothing to say. `limit_runway_notify()` raises one `NOTIFY` when a limit crosses into the 30-day
window and one more on each halving of it, 15, 7, 3 and 1 days, and nothing in between. Escalation
compares against the urgency at the **last notification**, not against the previous sample: a date
only ever gets closer, so a sample-by-sample comparison would fire on every sample, which is the
failure the state table exists to prevent. `limit_runway_notify_resolved()` raises `cleared` once and
forgets the subject, so the same limit approaching again alerts from the start rather than against a
high-water mark from a problem already fixed. State lives in `limit_runway_alert`; the ladder lives in
`limit_runway_urgency()`, a pure function so the sender and the resolver read it the same way. A
finding the tool cannot establish never notifies: a gap in coverage is not an event. The design,
including why the ladder is five geometric edges rather than three, is in
[docs/command.md](docs/command.md). No existing object changes, so the update path is additive.

`limit_runway_command()`, the Act stage, is not here. It is next.

## 0.2.2 (2026-10-14)

A correction with a consequence. A sequence that a column fills by `DEFAULT` and not by
`OWNED BY` has no `pg_depend` row, so this extension could not read the column, and it
reported the sequence's own `MAXVALUE` as the effective limit. For an `int4` column beside a
`bigint` sequence that number is too permissive: the column runs out at 2147483647 and the
sequence's ceiling is far above it, so the finding said there was room the next insert did
not have.

- `limit_runway_sequences()` returns two new columns, `dflt_object` and `dflt_coltype`: the
  column whose `DEFAULT` calls `nextval()` on this sequence, and its type, populated only
  when no dependency ties the two together.
- `limit_runway_findings()` adds an unknown for that shape, naming the column and the fix:
  `ALTER SEQUENCE ... OWNED BY ...`.
- The update path drops and recreates `limit_runway_sequences()`, because a `RETURNS TABLE`
  function's row type is part of its signature and cannot be changed by `CREATE OR REPLACE`.

## 0.2.1 (2026-10-12)

**No SQL changed over 0.2.** The tag exists so the tag matches the tree: 0.2.1 carries a
corrected status line in the README, the doc-facts lint, and a scenario installer that
lists every release and update script rather than a chosen subset.

- `scenarios/install-extension.sh` gained the 0.2.1 release script. Without it the
  GitHub scenario job installed 0.2.1's extension directory and found no file for the
  new `default_version`, and reported the extension as not installed on the server. The
  lint now fails if any release, update or control file is on disk, in `DATA`, and
  absent from that explicit list.
- README: the status line said 0.1 with no dates and not tagged while step 5 said 0.2
  was done. Corrected, and a lint rule now fails when a document claims an untagged or
  unreleased extension while a tag exists.

Upgrading: `ALTER EXTENSION pg_limit_runway UPDATE TO '0.2.1';` from 0.2. A no-op SQL
path.

## 0.2 (2026-10-11, tag v0.2.0)

The first release. Adds history, and with it the projected dates that are the point of
the tool.

- `limit_runway_sample()` appends one row per limit per sample, on the caller's rights,
  scheduled hourly. It is the only writer.
- `limit_runway_history` holds the samples, one epoch per series.
- `limit_runway_prune()` forgets samples older than 35 days.
- A date appears wherever two samples in one unbroken series show real movement. One
  sample reports "no rate yet"; a series that has not moved reports "not moving".
  Neither is a date.
- A new epoch starts whenever the position falls or the limit changes, so a restore, a
  cycling sequence's wrap and a raised `MAXVALUE` each break the series rather than
  being fitted across. Where the 7-day and 24-hour rates disagree by more than a factor
  of two, both dates are reported, ranked by the sooner.
- Sequences are sampled from `limit_runway.sample_min_used` (10% by default) used, and
  a sequence already sampled is always sampled again so its series never loses its
  start. A limit the scheduling role cannot read is reported as not established, never
  as a zero that reads as fine.

Upgrading: `ALTER EXTENSION pg_limit_runway UPDATE TO '0.2';` from 0.1.

How rates are measured: [docs/rate.md](docs/rate.md). How 0.2 implements them, and
what it still does not know: [docs/history.md](docs/history.md). How findings are
ordered: [docs/ranking.md](docs/ranking.md).

## 0.1

Current state only: every hard limit the server can see, with no history and no dates.
**Never tagged**, so there is no public 0.1 to install from. The 0.1 release script and
the 0.1 to 0.2 update path ship, because an installation built from a pre-0.2 checkout
still needs a path forward.