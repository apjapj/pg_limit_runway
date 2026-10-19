# level and previous_level on the alerting payload (0.5.0)

The shared contract in [`ALERTS.md`](https://github.com/apjapj/pg_incident_watch) carries an onset and an escalation on
the same `alerting` event. A consumer tells them apart by `previous_level`: null at onset, the
previous level at each escalation. `level` is the notification count read after the increment:
1 at onset, 2 at the first escalation, and so on.

Until 0.5.0 this tool sent a third value, `escalated`, and no level. [`ALERTS.md`](https://github.com/apjapj/pg_incident_watch) reserves
`escalated` and says no tool sends it, and the other two tools already tell the two apart with
`level` and `previous_level` on `alerting`. 0.5.0 aligns this tool with them:

- `limit_runway_notify()` sends `event = 'alerting'` for both onset and escalation, and adds
  `level` and `previous_level`.
- `limit_runway_notify_resolved()` adds `level` to the `cleared` payload: the last level the
  incident reached. `previous_level` is absent there, not present and null.
- No signature, returned column or table changes. Both functions are replaced with
  `CREATE OR REPLACE`, so grants and comments survive. The update path is 0.4.1 to 0.5.0.

`escalated` stays in the contract's vocabulary as a reserved value, so nothing is removed; this
tool simply stops sending it.

The B2 alerting chapter depends on all three tools sending the same keys. This release is the
last of the three.
