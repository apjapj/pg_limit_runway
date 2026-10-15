# contributing: changing this, and releasing it

Short version of what CI runs and what it will not catch for you. `pg_lock_tree`'s
CONTRIBUTING.md is the long version and is worth reading once; this file is what
applies to a repository with 19 scenarios, 148 tests and thirteen release and update scripts.

## Make targets

| Target | What it does | Needs |
|---|---|---|
| `make install` | Installs the control file and every release and update script in `DATA` via PGXS. | A superuser shell and the server headers (`postgresql-server-dev-NN`). |
| `make prove` | `pg_prove --dbname $(TESTDB) test/*.sql`. Default `TESTDB` is `postgres`; override it with `make prove TESTDB=...`. | An installed extension and a running server. The libpq variables in your environment pick the server. |
| `make lint` | Three scripts, no database: `scripts/lint-docs.sh`, `scenarios/check-evidence.sh`, `scripts/check-workflows.sh`. | Nothing. Safe anywhere, cheap enough for a pre-commit hook. |

CI runs `make lint` and the tests on PostgreSQL 14 and 18, and runs the scenario suite in
a container built from `ci/Dockerfile`. It does not run `make install` against your
machine, so an install that works in CI and not locally is a bug in the `DATA` list or in
`scenarios/install-extension.sh`, and both are checked by the lint.

## The rules a change must not break

These are the promises the documentation makes. Each has a test or a scenario, so a
change that breaks one will go red rather than pass quietly.

- **The caller's rights.** Nothing is `SECURITY DEFINER`. Every function and the view run
  as the caller, so a monitoring role sees exactly what its grants allow. Three helpers
  stay executable by `PUBLIC` on purpose: `limit_runway_project`,
  `limit_runway_projection` and `limit_runway_sequences`. `limit_runway_findings()` calls
  them with the caller's rights, so a monitoring role needs only two grants; revoking
  them breaks both the monitoring role and the sampler. `test/01_limit_runway.sql` pins
  the exact set, so a change that closes one of them goes red rather than quiet.
- **Closed by default.** Everything else is revoked from `PUBLIC`. A limit the
  scheduling role cannot read is reported as not established, never as a zero that reads
  as fine.
- **Never waits for a lock.** Anything the sampler cannot finish in `lock_timeout` is
  not established.
- **Never runs a fix.** The extension names statements such as `setval` as text for a
  human to read. It must never execute one.
- **Pure SQL, PostgreSQL 14 and later.** No C, no background worker, no
  `shared_preload_libraries`, no restart.

## Tests

`test/01_limit_runway.sql` is `plan(38)`, `test/02_history.sql` is `plan(33)`, `test/03_notify.sql` is
`plan(25)`, `test/04_command.sql` is `plan(42)` and `test/05_upgrade.sql` is `plan(10)`. The plans must
match the assertion counts; the lint does not check that here, so if you add an assertion, count it.

### A test that cannot fail is not a test

An assertion that would pass whatever the code did is worse than no assertion, because
it counts towards the plan and reads as evidence. Two traps specific to this repository:

- A query that **errors** on a type cast and returns nothing compares equal to another
  empty result, so "the output matches" passes for the wrong reason. Run the query on its
  own and read the result before trusting a comparison built from it.
- **A measurement against a server-wide counter is a bound, not a number.** `s19` reads
  the server-wide xmax across a sample to show the sampler takes O(1) transaction ids
  rather than O(n). A concurrent autovacuum or any other backend can also take an xid
  between the two reads, so the assertion is a range. It was an exact equality once and
  flaked. If you write a cost claim, say what it is a bound against and what else can
  move the counter.

## Scenarios and evidence

```
./scenarios/run.sh          # every scenario, teardown before each; masked evidence to scenarios/evidence/
```

`scenarios/run.sh` sources `scenarios/mask.sh`, which replaces the volatile values (timestamps, pids, sizes,
rates) with named tokens. The masked capture is written to `scenarios/evidence/` and is
**committed**. Every numeric figure the documentation states is linked to the evidence
file it came from, and `scenarios/check-evidence.sh` fails if a figure in a document is
not in the file it links to.

CI compares the evidence byte for byte against what is committed, with **no report-only
mode**. That is deliberate and it is the difference from pg_bloat_cause, which started
report-only and is now strict too: a comparison that is red for environmental reasons
on its first day teaches everyone to ignore red runs. These scenarios print no ids or
timestamps and have been byte-identical across runs on two versions, so there was
nothing to soften. So:

- **If you change what a scenario prints, regenerate the evidence and prove it is
  deterministic.** Run it three times and confirm the files are identical. A capture
  that varies between runs is a red run nobody can fix.
- To diagnose a difference, run `./scenarios/run.sh` yourself and read
  `git diff scenarios/evidence/`. The diff is the answer; do not weaken the check to get
  past it.

The one place files are hand-copied into a container is
`scenarios/install-extension.sh`, which copies by an **explicit file list** with a
per-file `md5sum` check. When you add a release or update script, add it there too. The
lint fails if a file is on disk, in `DATA`, and absent from that list, and that is not
hypothetical: 0.2.1 shipped without its script in the list, and the GitHub scenario job
reported the extension as not installed while Forgejo stayed green, because Forgejo
installs through `make install`.

## Proving a check fails

If you change a check, show it failing first. A check that was never seen to fail is not
evidence that it can.

```bash
# 1. break exactly one thing, and keep the break small enough to name in a sentence
# 2. reinstall, or copy the file into the container again; without this the next command
#    tests nothing
# 3. run the check and watch it fail. A check that passes here tells you the break did
#    not land, which is worth knowing before you change the check
# 4. restore, reinstall, and run it again to see it pass
```

## Releasing

1. Increment the version. The release script is `pg_limit_runway--<new>.sql`, the
   `.control` `default_version` names it, and `DATA` lists it. An update path from the
   previous version is `pg_limit_runway--<old>--<new>.sql` and also goes in `DATA`.
2. Add both to `scenarios/install-extension.sh`'s `FILES` list.
3. Add a `CHANGELOG.md` entry. If it changes what a user sees, say what they will see
   differently.
4. Update the README status line and any document that names the version. The lint fails
   if a document claims the release is untagged or unreleased while a tag exists, and
   fails if the README header does not mention the current version.
5. `make lint`, `make prove` on 14 and 18, and the scenario suite green on both.
6. Tag it, one name at a time, never with `--tags`. A released tag is never edited,
   never amended and never moved.

If a release changes no SQL and exists only so the tag matches the tree, say so
explicitly in the changelog and in the release notes. 0.2.1 is the precedent.

## Workflow policy

Three rules every workflow in this repository follows, so a change to one file does not
quietly break the posture the others keep:

- **Actions are pinned to a commit SHA**, with the release in a trailing comment:
  `actions/checkout@<40-hex> # v4.4.0`. A tag such as `@v4` is a moving reference: whoever
  controls the upstream tag controls what runs in this repository, and the change lands
  without a review here. To move it, resolve the tag yourself
  (`git ls-remote https://github.com/actions/checkout refs/tags/v4`), replace the SHA, and
  put the new version in the comment in the same commit, so the diff shows both.
- **`permissions: contents: read` at the top of every workflow.** No job here writes to
  the repository, creates a release, or needs a wider token. Stating it means a later
  change cannot quietly widen it, and it stops a workflow inheriting whatever the
  repository default happens to be.
- **The Forgejo and GitHub copies are kept deliberately parallel.** They differ only in
  `runs-on`, the job image note and the log-retention sentence. They are not kept in step
  by a generator, because the point of the second copy is that the public repository
  proves what the private one proves, and a generator is one more thing that can be
  right while both copies are wrong. When you change one, change the other, and say in the
  commit that you did.

## House style

No em-dashes or en-dashes in any document, comment, script or workflow. The lint checks
it, and a reader's eye catches it before anything else.