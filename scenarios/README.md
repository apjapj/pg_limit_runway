# Scenario fixtures

One script per limit, each building the real situation on a scratch server and printing three things:
what the usual check reports, what actually happens (often the error itself), and the evidence a tool
would read. A `PASS`/`FAIL` line asserts each claim; `run.sh` reports a scenario with a FAIL as FAILED.
They exist so that every claim in [docs/rate.md](../docs/rate.md) and [docs/ranking.md](../docs/ranking.md)
can be checked against a run. No extension SQL exists yet.

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

**PostgreSQL 14 and 18 agree on every scenario except s10**, where `reserved_connections` exists on 18
only and 14 says so. **Reproducible**: two consecutive runs on each version gave byte-identical evidence
for all 24 files with no masking at all, because the scenarios print facts and booleans rather than ids,
pids or timestamps; `mask.sh` keeps pg_bloat_cause's convention for when one is needed.
