# changelog

Versions are listed newest first. Released tags are never edited: a change that needs
a new entry gets a new version.

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