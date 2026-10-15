# changelog

Versions are listed newest first. Released tags are never edited: a change that needs
a new entry gets a new version.

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