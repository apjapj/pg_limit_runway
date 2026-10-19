-- pg_limit_runway 0.4.1 -> 0.5.0
--
-- Adds the two escalation keys of the shared pg_incident_watch alert contract to the alerting
-- payload: `level` and `previous_level`. It also sends `event = 'alerting'` for an escalation,
-- not the reserved `escalated`; a consumer tells onset from escalation by `previous_level`.
-- Both are additive, so nothing built against 0.4.1 breaks, and no existing key is removed.
--
--   limit_runway_notify()          the alerting payload gains `level` and `previous_level`.
--                                  `level` is the notified_count read AFTER the increment:
--                                  1 at onset, prior + 1 at each escalation.
--                                  `previous_level` is that minus one: null at onset.
--   limit_runway_notify_resolved() the cleared payload gains `level`, the last level reached,
--                                  the swept row's notified_count. `previous_level` is absent
--                                  there, not present and null.
--
-- No signature, returned column or table changes. Both functions are replaced with CREATE OR
-- REPLACE, never DROP, so grants and COMMENTs survive. The meaning of the keys is pinned by
-- ALERTS.md in the pg_incident_watch umbrella repository, so the tools cannot drift.

\echo Use "ALTER EXTENSION pg_limit_runway UPDATE TO '0.5.0'" to load this file. \quit

CREATE OR REPLACE FUNCTION @extschema@.limit_runway_notify(
  channel  text     DEFAULT 'limit_runway',
  within   interval DEFAULT interval '30 days',
  min_used numeric  DEFAULT 0.5)
RETURNS bigint
LANGUAGE plpgsql
-- A monitor never waits behind a lock, and reading a finding can wait for one. Same guard as the view.
SET lock_timeout = '1s'
AS $fn$
DECLARE
  ch      text := channel;
  f       record;
  subj    text;
  u       integer;
  prev    integer;
  ev      text;
  -- The two escalation keys of the shared contract. level is the notification count read AFTER
  -- the increment: 1 at onset, prior + 1 at each escalation. previous_level is that minus one,
  -- so it is null at onset and the previous level at every escalation.
  new_level  integer;
  prev_level integer;
  raised  bigint := 0;
  payload text;
BEGIN
  FOR f IN SELECT * FROM @extschema@.limit_runway_findings(min_used)
  LOOP
    u := @extschema@.limit_runway_urgency(f.rank_class, f.until_date, f.used_fraction, within);
    CONTINUE WHEN u = 0;   -- nothing worth saying: not established, or outside the window
    subj := f.kind || ' ' || f.object;
    SELECT a.urgency INTO prev FROM @extschema@.limit_runway_alert a
     WHERE a.channel = ch AND a.subject = subj;
    IF NOT FOUND THEN
      INSERT INTO @extschema@.limit_runway_alert
        (channel, subject, kind, object, event, urgency, notified_count)
      VALUES (ch, subj, f.kind, f.object, 'alerting', u, 1);
      ev := 'alerting';
      new_level  := 1;
      prev_level := NULL;
    ELSIF u > prev THEN
      -- Materially worse than at the LAST notification, never than the previous sample. A date only
      -- gets closer, so the previous-sample comparison would be true on every sample.
      --
      -- The event stays 'alerting': the contract carries an escalation on the same event and tells
      -- it apart by previous_level. 'escalated' is reserved and sent by no tool. level is the count
      -- read AFTER the increment, so RETURNING gives it directly rather than a second read.
      UPDATE @extschema@.limit_runway_alert
         SET event = 'alerting', urgency = u, notified_at = now(), notified_count = notified_count + 1
       WHERE limit_runway_alert.channel = ch AND limit_runway_alert.subject = subj
      RETURNING notified_count INTO new_level;
      ev := 'alerting';
      prev_level := new_level - 1;
    ELSE
      CONTINUE;   -- same severity or better: silent, which is the whole point
    END IF;
    payload := json_build_object(
      'tool', 'pg_limit_runway', 'channel', ch, 'event', ev, 'subject', subj,
      'sampled_at', now(), 'kind', f.kind, 'object', f.object,
      'level', new_level, 'previous_level', prev_level,
      'tier', CASE WHEN u >= 6 THEN 'act' WHEN u >= 4 THEN 'schedule' ELSE 'plan' END,
      'until_date', f.until_date,
      'days_left', CASE WHEN f.until_date IS NOT NULL
                        THEN round(extract(epoch FROM f.until_date - now()) / 86400, 1) END,
      'state', f.state, 'summary', f.detail)::text;
    PERFORM pg_notify(ch, payload);
    raised := raised + 1;
  END LOOP;
  RETURN raised;
END
$fn$;

COMMENT ON FUNCTION @extschema@.limit_runway_notify(text, interval, numeric) IS
  'Raise a NOTIFY on channel when a hard limit crosses into within (default 30 days), again on each '
  'halving of the window (15, 7, 3, 1 days), and once per subject. Returns how many it raised, so zero '
  'is the normal result. Schedule it beside limit_runway_sample().';

CREATE OR REPLACE FUNCTION @extschema@.limit_runway_notify_resolved(
  channel  text     DEFAULT 'limit_runway',
  within   interval DEFAULT '30 days',
  min_used numeric  DEFAULT 0.5)
RETURNS bigint
LANGUAGE plpgsql
SET lock_timeout = '1s'
AS $fn$
DECLARE
  ch      text := channel;
  s       record;
  u       integer;
  raised  bigint := 0;
  payload text;
BEGIN
  FOR s IN SELECT * FROM @extschema@.limit_runway_alert a WHERE a.channel = ch
  LOOP
    SELECT @extschema@.limit_runway_urgency(f.rank_class, f.until_date, f.used_fraction, within)
      INTO u
      FROM @extschema@.limit_runway_findings(min_used) f
     WHERE f.kind = s.kind AND f.object = s.object;
    IF u IS NULL THEN
      u := 0;   -- the limit is gone from the findings, so it is as clear as a date that moved out
    END IF;
    CONTINUE WHEN u > 0;   -- still standing: a resolution notice with no matching clear is noise
    payload := json_build_object(
      'tool', 'pg_limit_runway', 'channel', ch, 'event', 'cleared', 'subject', s.subject,
      'sampled_at', now(), 'kind', s.kind, 'object', s.object,
      -- The last level the incident reached. previous_level is deliberately absent on cleared.
      'level', s.notified_count)::text;
    DELETE FROM @extschema@.limit_runway_alert a WHERE a.channel = ch AND a.subject = s.subject;
    PERFORM pg_notify(ch, payload);
    raised := raised + 1;
  END LOOP;
  RETURN raised;
END
$fn$;

COMMENT ON FUNCTION @extschema@.limit_runway_notify_resolved(text, interval, numeric) IS
  'Raise one cleared NOTIFY per subject that had alerted and no longer crosses into within, then '
  'forget its state so the same limit approaching again alerts from onset. Run it beside '
  'limit_runway_notify() with the same thresholds.';

