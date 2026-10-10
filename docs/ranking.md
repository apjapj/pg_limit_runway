# ranking: which limit comes first, and what a row can say

**For: whoever writes `limit_runway` and `limit_runway_text()`.** Settled before any SQL. Figures link to
the scenario evidence; `scenarios/check-evidence.sh` checks them.

## Three finding states, as in pg_bloat_cause

- **established**: the limit, the current value, and either a date, a fixed boundary, or "reached";
- **secondary**: a second fact about the same limit that changes what to do, as a `then:` line;
- **not established**: the tool cannot see enough to say, and says so instead of reporting "fine". The
  member space of MultiXacts for a role without superuser (s6) is the standing example.

## The order

1. **Reached, failing now.** Inserts are being refused today: s1's column, s2's identity, s4's foreign key,
   s7's missing partition, s3's cycling sequence colliding, s12's sequence behind its data. These outrank everything, however close
   anything else is.
2. **A date**, soonest first: projected from a rate (sequences, XIDs, MultiXacts, slots with
   `max_slot_wal_keep_size`), or fixed (password expiry, the last partition's bound). One timeline: a
   password that expires in 3 days sorts before a sequence projected to run out in 30.
3. **No rate yet**: one sample only. Ordered by the share of the limit already used, and marked, because
   "close" without a rate is not a date.
4. **Peaks** (connections): ordered by peak use as a share of the limit, after anything with a date.
5. **Not established** last, but listed: a limit the tool could not read is a gap, not an absence.

The worked case is **s11**: an int2 identity with [6](../scenarios/evidence/s11_two_limits.pg18.txt) of
[32767](../scenarios/evidence/s11_two_limits.pg18.txt) values left, still accepting inserts, and a
time-partitioned table whose last partition ended on `2026-02-01`, refusing every insert for the present.
The partition comes first. The sequence is closer in every number a dashboard shows and is not failing.

## Secondary lines the scenarios forced

- **A DEFAULT partition** (s7): the row past the last bound went into the DEFAULT
  ([1](../scenarios/evidence/s7_partitions.pg18.txt) row) instead of failing, which hides the limit, and that
  row then blocked creating the partition it belongs in. The finding is the boundary, with `then: the
  DEFAULT holds rows for this range, so the partition cannot be created until they are moved`.
- **An expired password** (s9): `then: logins that do not use a password are not affected`, because the
  expired role still logged in over a trusted local socket.
- **Connection limits** (s10): `then: superusers are exempt from this limit`, because a superuser was let
  into a database already at its limit.
- **A forced vacuum** (s5): the XID finding does not clear because a vacuum ran; it clears when the age falls.
