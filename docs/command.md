# command and alerting: the Act and Detect contract, settled before any code

**Status: implemented.** `limit_runway_notify()` and `limit_runway_notify_resolved()` shipped in 0.3.0
and `limit_runway_command()` in 0.4.0, with 0.4.1 a quoting fix to the command and no shape change.
This is the contract for all three, written down before any SQL so the work started from decisions
rather than from questions. `README.md` step 6 states the trigger and the ladder; this document is the
authority for everything it does not.

The shared payload contract is [ALERTS.md](https://github.com/apjapj/pg_incident_watch) in
`pg_incident_watch`, and it is not negotiable here: the five required keys, the `event` vocabulary,
the channel naming, and the rule that escalation is compared against the **last notification** and
not the last sample. What this document settles is the one thing that contract leaves to each tool:
what "materially worse" means for a limit with a date.

## What it will be

```
limit_runway_command(min_used numeric DEFAULT 0.5)
  RETURNS TABLE (
    tier     text,   -- 'plan' | 'schedule' | 'act'
    kind     text,   -- 'sequence', 'xid', 'partition', ...
    object   text,   -- the qualified name or identity the finding carries
    command  text,   -- one runnable statement, always the least destructive that can work
    note     text    -- the cost, or why this is not the fix
  )

limit_runway_notify(
  channel  text     DEFAULT 'limit_runway',
  within   interval DEFAULT interval '30 days',
  min_used numeric  DEFAULT 0.5
) RETURNS bigint

limit_runway_notify_resolved(
  channel  text     DEFAULT 'limit_runway',
  within   interval DEFAULT interval '30 days',
  min_used numeric  DEFAULT 0.5
) RETURNS bigint
```

`limit_runway_command()` is the Act stage, and it is shaped like `pg_lock_tree`'s
`lock_tree_command()`: one runnable statement per finding, for pasting or for
`SELECT command FROM limit_runway_command() \gexec`. The `tier` column is new to this tool. The exact
statement for each limit kind is settled in [docs/act.md](act.md).

The two notify functions are the Detect stage. They keep state in a `limit_runway_alert` table, one
row per subject per channel, exactly as `pg_lock_tree`'s `lock_tree_alert` holds high-water marks.

## The escalation ladder, in full

`README.md` says the escalation is the window halving, 30, 15, 7, 3, 1, which is `pg_lock_tree`'s
wait-doubling read backwards. That is the **five geometric edges**, and this document settles them:

| edge | a notification fires when the projected window first falls under |
|---|---|
| onset | `within`, 30 days by default |
| escalate | 15 days |
| escalate | 7 days |
| escalate | 3 days |
| escalate | 1 day |

Onset is the first edge, so a problem watched from thirty days out produces five events and no more:
one `alerting`, four `escalated`, then one `cleared` when it clears. That is the whole point of a
geometric ladder and the reason a linear one is wrong. A ladder of 30, 29, 28, ... would fire daily.
A ladder of 30, 7, 1 fires twice and can take a two-day problem from onset straight to urgent with
nothing in between. The halving keeps the **factor** between notifications roughly constant, which
is what makes each one read as "twice as bad as last time" and keeps the count logarithmic.

The comparison is against the **lowest edge already notified**, stored in `limit_runway_alert`, never
against the previous sample. A date only ever gets closer, so comparing to the last sample would be
true on every sample and would notify every sample, which is the failure `lock_tree_alert` exists to
prevent reached by a different route. `event` is `escalated` and not `alerting`: unlike `pg_lock_tree`,
which sends `alerting` for both and says so, this tool has a discrete and obvious edge and implements
the distinction the contract defines.

Clearing forgets the stored state, so the same limit approaching again later alerts from onset rather
than escalating against a high-water mark from a problem that was already fixed.

## The three tier labels

The five edges drive the notification. The **tier** drives the command, and it is a coarser, human
grouping of the same ladder, so a reader of `limit_runway_command()` is told what to do without being
told a number of days:

| tier | when | what it means |
|---|---|---|
| `plan` | more than 7 days left, or under half the limit used | the statement and its cost, no urgency |
| `schedule` | 1 to 7 days left, or 0.5 to 0.875 of the limit used | do it this week |
| `act` | under 1 day left, 0.875 or more used, or failing now | do it now |

The tier is `limit_runway_urgency()` grouped, so the date half and the share half cross the labels on
the same geometric edges the notification uses. A no-date finding (connection headroom, a "no rate
yet" row) has no days left, so it reaches `schedule` from 0.5 of the limit used and `act` from 0.875,
which is the halving of the remaining headroom the "findings with no date" section below sets out.

A finding that is already failing (state `reached`, `exhausted`, `cycled into existing keys`, a
partition past its last bound) is `act` whatever its date, because there is no date and the insert is
being refused now. The tier is a function of the finding, not of the operator's threshold. The top of
`plan` is the `within` window at its default: `limit_runway_command()` takes no `within` argument, so
its command list is the 30-day window the readers default to, and `limit_runway_notify(within => ...)`
set narrower would notify on a smaller set and not act on it. At the defaults the command list and the
alert window describe the same set.

## Findings with no date

Half the limits have no slope, and `README.md` step 2 already says so: a password expiry is a fixed
date, connection headroom is a peak and not a slope, a partition runs out on a bound, and a limit
with one sample has "no rate yet". The five-edge ladder applies only where there is a projected date.
The rest need their own definition of materially worse or they never escalate:

- **A fixed date** (password expiry, the last partition bound) has a date, so the five edges apply
  unchanged. Nothing special is needed.
- **A peak or a share** (connection headroom, and every "no rate yet" row) escalates on the share of
  the limit already used, on the halving of the **remaining headroom**: notification at a used
  fraction crossing 0.5, then 0.75, then 0.875. Remaining headroom halving is the same geometric idea
  as the window halving, applied to the quantity this finding actually has an edge in.
- **Not established** never notifies. A limit the tool cannot read is a gap in coverage, and a gap is
  not an event: paging on "I do not know" trains the operator to ignore the channel. It stays listed
  by the view, which is where a gap belongs, and `limit_runway_notify()` says nothing about it. This is
  the same decision `ranking.md` already made for ordering, applied to alerting.

## The payload

The five required keys, plus this tool's own, all additive per the contract's rule 1:

```
{
  "tool":       "pg_limit_runway",
  "channel":    "limit_runway",
  "event":      "alerting" | "escalated" | "cleared",
  "subject":    "sequence public.orders.id",
  "sampled_at": "2026-10-15T09:12:04+01:00",
  "kind":       "sequence",
  "object":     "public.orders.id",
  "tier":       "schedule",
  "until_date": "2026-10-20T00:00:00+01:00",
  "days_left":  4,
  "state":      "date",
  "summary":    "public.orders.id (int4) runs out on 20 October at the current rate"
}
```

`subject` is the limit's identity and must be stable for the life of the problem, per the contract's
long note on the subject key. It is built from the finding's own two fields, `<kind> <object>`, so it
is stable by construction and a listener can rebuild it from the payload's other keys:

| kind | subject | example |
|---|---|---|
| `sequence` | `sequence <schema>.<table>.<column>`, or the sequence alone when no column owns it | `sequence public.orders.id` |
| `foreign key` | `foreign key <schema>.<table>.<column>` | `foreign key public.shipments.order_id` |
| `xid` | `xid <object>`, a database or a table | `xid database postgres` |
| `multixact` | `multixact <object>` | `multixact member space` |
| `partition` | `partition <schema>.<table>` | `partition public.events` |
| `replication slot` | `replication slot <slot_name>` | `replication slot standby_a` |
| `connections` | `connections <object>` | `connections server` |
| `password` | `password role <rolname>` | `password role reporting` |

The identity a sequence carries is the **column** that fills it, not the sequence's own name: that is
the object `limit_runway_findings()` already uses everywhere, and a subject that disagreed with the
finding's `object` would make a listener correlate two names for one limit. The subject is never the
OID, for the reason the contract gives: a listener reading a log a week later cannot resolve one.

## The order of work, and why it is that order

1. **The tests and scenarios**, with all three functions absent, so they fail loudly.
2. **`limit_runway_command()`**, which is pure and needs no state.
3. **`limit_runway_notify()` and `_notify_resolved()`**, which need the state table.
4. **The documents**, if and only if the implementation shows a sentence needs amending. The ladder
   is already written in `README.md`; only its three tiers and the no-date rule are new here.
5. **`INSTALL.md`**, with the grant the state table needs.
6. **Version 0.3.0**, a new release script and an update path, never an edit to 0.2.2.

Building the harness before the thing it tests is deliberate, and it is what this repository learned
the hard way: `bloat_cause_holder()` shipped broken with every gate green because nothing called it,
and the `DEFAULT nextval()` detection here raised for an unprivileged caller because only the
privileged path was exercised.

## Verification, and the paths that will actually find faults

**The ladder, without waiting a month.** This is the hard one and the reason it is written down. The
projected `until_date` comes from the slope of the history, so a scenario can plant samples whose
slope puts the date at a chosen distance on a chosen `sampled_at`, call `limit_runway_notify()`, and
assert one escalation per edge. The test that matters is the **silence**: two consecutive calls with
the date unmoved must produce zero, and a date that moves but stays above the next edge must also
produce zero. A function that notifies on every closer sample passes the "it escalated" half and
fails this one, so the silence assertions are the ones to write first.

**An unprivileged role, not last.** The state table needs write access, and this is the path that
found the `findings()` defect and the s18 permission regression, neither of which reading the SQL
found. A monitor role without the grant must get a clear error from the notify functions and must not
affect the view.

**The required keys.** A pgTAP assertion that every payload carries `tool`, `channel`, `event`,
`subject` and `sampled_at`, which is the check that keeps the family a family.

**`limit_runway_command()` against the view.** Every `command` must be a single statement, and the
test should assert that the set of objects it returns matches the set `limit_runway()` reports as
needing action, so the two cannot drift.

## What must not change

- `limit_runway`, `limit_runway_findings()`, `limit_runway_text()` and the history functions keep
  their shapes, with one decided exception: 0.4.0's additive `from_date` column on the findings and the
  view, so `limit_runway_command()` can build a partition with an exact width (docs/act.md). Alerting
  reads `limit_runway_findings()`; it does not alter it.
- No query text and no credentials in a payload, per the contract's rule 5. A password finding names
  the role and the date and never the password, which is what `README.md` already promises.
- Version: each stage is a new release and a new update path, not an edit to a released version. The
  Detect stage is 0.3.0; the Act stage is 0.4.0, whose update drops and recreates the findings function
  and the two readers that depend on it, and restates their grants (docs/act.md has why).

## What shipped, and the one thing left open

The ladder and its silence half are `test/03_notify.sql`, written against the functions absent; the Act
stage is `test/04_command.sql`, written the same way, one fixture of each kind, with the internal
per-row derivation carrying the kinds a single transaction cannot build. Both are in 0.4.0 and 0.3.0.
`test/05_upgrade.sql` is 0.4.1's other half: it is the first test to run an update path at all, because
every other test installs the default version from scratch and the drop-and-recreate SQL a release
ships otherwise goes unexecuted by every gate.

Left open on purpose: `from_date` is the only field the command needed and did not have, so it is the
only one added. A limit whose finding still cannot build a complete statement produces no row rather
than a placeholder, which is the first rule in docs/act.md, not a gap to close later.
