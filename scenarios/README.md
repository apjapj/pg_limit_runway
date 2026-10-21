# Scenario fixtures

One script per limit, each building the real situation on a scratch server and printing three things:
what the usual check reports, what actually happens (often the error itself), and the evidence a tool
would read. A `PASS`/`FAIL` line asserts each claim; `run.sh` reports a scenario with a FAIL as FAILED.
They exist so that every claim in [docs/rate.md](../docs/rate.md) and [docs/ranking.md](../docs/ranking.md)
can be checked against a run. When `pg_limit_runway` is installed on the server, each scenario also
prints what the extension says about its objects and asserts the finding [docs/ranking.md](../docs/ranking.md)
predicts (`PASS  finding for ...`): state, class, `then` lines and `unknowns`. s3 and s13 check twice, before
and after their sequences run out or wrap; s6 checks as superuser and as a `pg_monitor` role; s8 in both halves.
`scenarios/install-extension.sh <container>` copies it in, md5-verified.

```bash
export PGHOST=127.0.0.1 PGPORT=5818 PGUSER=postgres PGPASSWORD=... LR_CONTAINER=<container>
./scenarios/run.sh            # all, teardown between each; masked evidence to scenarios/evidence/
./scenarios/check-evidence.sh # every linked figure is in its evidence file
```

Run them on a scratch server: s5 burns 110,000 transaction ids, s8 changes `max_slot_wal_keep_size` with
`ALTER SYSTEM` (and resets it), s9 and s10 create roles and a database. `LR_CONTAINER` lets s9 log in over
the container's local socket. The runs below used throwaway containers from the pg_lock_tree matrix
images, started with `postgres -c autovacuum_naptime=10s -c log_autovacuum_min_duration=0`.

| Scenario | What it showed | Differs from what the README assumed? |
|---|---|---|
| `s1_serial_bigint_seq` | a bigint sequence on an int4 column: the usual check says [0.000000](evidence/s1_serial_bigint_seq.pg18.txt)% and the insert fails | **yes**: the failed insert consumed a value, leaving the sequence at [2147483648](evidence/s1_serial_bigint_seq.pg18.txt), past the column's maximum |
| `s2_int2_identity` | [32767](evidence/s2_int2_identity.pg18.txt) rows, then "reached maximum value" | no; the usual check is right here, since an identity sequence takes the column's type |
| `s3_negative_maxvalue_cycle` | descending runs out at min_value; MAXVALUE [1000](evidence/s3_negative_maxvalue_cycle.pg18.txt) on a bigint column; CYCLE wraps and collides | no |
| `s4_widened_parent_fk` | parent bigint past 2^31, child int4: "integer out of range" | no |
| `s5_xid_age` | the snapshot read assigns no xid, `pg_current_xact_id()` does; the forced vacuum runs with autovacuum off | **yes**: the forced vacuum froze nothing with the default `vacuum_freeze_min_age`, so the age did not fall |
| `s6_multixact` | [100](evidence/s6_multixact.pg18.txt) multixacts from 100 rounds over 50 rows; member space unreadable to `pg_monitor` | **yes**: consumption is per distinct locker set, not per row (5000 was predicted) |
| `s7_partitions` | no DEFAULT: insert fails; DEFAULT: insert lands there ([1](evidence/s7_partitions.pg18.txt) row) and the partition can no longer be created; integer key skipped | **yes**: a DEFAULT is not a safety net, it blocks the fix |
| `s8_slot_wal_keep` | unset: `reserved`, `safe_wal_size` NULL; set to 32MB: `unreserved`, then `lost` | no |
| `s9_valid_until` | expired refuses password logins, [3](evidence/s9_valid_until.pg18.txt) days, `infinity` and NULL all log in | **yes**: the expired role still logs in over a trusted socket |
| `s10_connection_headroom` | role at [2](evidence/s10_connection_headroom.pg18.txt) of 2 and database at 1 of 1 while the usual check shows plenty | **yes**: superusers are exempt from both limits |
| `s12_sequence_behind_data` | explicit ids loaded, sequence never advanced: the usual check exceeds 100% and the next default id collides | **yes**, found by Piotr: the sequence is *behind* the data, a state to report with its fix, not a projection |
| `s11_two_limits` | a partition already failing beside an int2 identity with [6](evidence/s11_two_limits.pg18.txt) left | the ordering case for [docs/ranking.md](../docs/ranking.md) |
| `s13_descending_cycle_and_step` | a descending CYCLE sequence counted [4](evidence/s13_descending_cycle_and_step.pg18.txt) values before the wrap, and 4 inserts then succeeded; a descending sequence by 3 at [2](evidence/s13_descending_cycle_and_step.pg18.txt) above its floor fails on its next call | **yes**, from Piotr's review of 0.1: the count was right for the cycling case and wrong for any step other than 1, which 0.1 now counts in calls |
| `s14_sequence_at_its_own_limit` | a sequence at its own MAXVALUE or MINVALUE has no next value, so the exhausted sentence names none | from Piotr's review of 0.1 |
| `s15_sampled_rate` | 0.2: three samples a day apart with 100 real inserts between: [100](evidence/s15_sampled_rate.pg18.txt) calls a day, 650 left, six and a half days, ranked after a password three days out | the first projected date: dates share one timeline |
| `s16_series_restart` | 0.2: a sequence restored backwards starts a new epoch, and the rate is the [50](evidence/s16_series_restart.pg18.txt) a day since, never a slope across the reset; a raised MAXVALUE starts one too | the rule rate.md asked for |
| `s17_rates_disagree` | 0.2: [16.43](evidence/s17_rates_disagree.pg18.txt) a day over the week, 100 over the last half day: both rates and both dates, ranked by the sooner | **yes**: it caught the 7-day window losing its anchor to the last tick's lateness, now 10% wide |
| `s18_sampler_rights` | 0.2: no grant on the history, the sampler refuses and names it; a sequence it cannot read is counted as not established and recorded as nothing | the caller's rights, as Piotr decided |
| `s19_sampler_cost` | 0.2: one sample over 10,000 sequences records the [100](evidence/s19_sampler_cost.pg18.txt) past 10% and consumes exactly one xid | the budget docs/history.md asked to be measured first |
| `s20_composite_fk` | a composite foreign key's `int4` child column against a `bigint` parent: the usual check says [0.000000](evidence/s20_composite_fk.pg18.txt)% used, the insert fails with "integer out of range", and 0.5.2 names the pair; the command then makes the insert succeed | **yes**, found by review: 0.5.1 read `conkey[1]`/`confkey[1]` only, so a composite pair was skipped in silence |

**The evidence is identical across the versions except for two scenarios.** `s10_connection_headroom`
differs from 16 on, where `reserved_connections` exists and 14 and 15 hold back
`superuser_reserved_connections` alone (14 and 15 agree, and 16, 17 and 18 agree);
`s12_sequence_behind_data` differs from 17, where the behind-the-data lookup shows an `Index Cond`
(14, 15 and 16 agree, and 17 and 18 agree). Every other scenario's files are byte-identical across
all six versions, and there are 120 committed files in all: one for each scenario on each of 14,
15, 16, 17, 18 and 19.
**Reproducible**: two consecutive runs on each version gave byte-identical evidence with no masking at
all, because the scenarios print facts and booleans rather than ids,
pids or timestamps. The extension's findings added one: s9's password expiry is set from `now()`, so
`mask.sh` replaces a run-time timestamp (one with fractional seconds) with `<run-time timestamp>`; s5
prints only its PASS lines, since its xid ages vary between runs. 0.2 adds a second rule: a projected date, printed to the minute, depends on
when the run happened, since samples are laid down relative to `now()`, so `mask.sh` replaces a date
with minutes and no seconds with `<date>`; the exact figures are asserted in SQL instead.
