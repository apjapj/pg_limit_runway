-- pg_limit_runway 0.2.2 -> 0.3.0: the Detect stage
--
-- New: limit_runway_alert (state), limit_runway_urgency() (the ladder), limit_runway_notify() and
-- limit_runway_notify_resolved(). No existing object changes, so this update is purely additive and
-- nothing has to be dropped and re-created. docs/command.md is the authority.
--
-- limit_runway_alert is state, not user data: it is the high-water mark the sender keeps, and it is
-- deliberately not registered with pg_dump.

\echo Use "ALTER EXTENSION pg_limit_runway UPDATE TO '0.3.0'" to load this file. \quit

-- ===================================================================================================
-- 0.3.0: the Detect stage. Alert on the projected date, one escalation per halving of the window.
-- docs/command.md is the authority for the ladder, the tier labels and the payload keys.
-- ===================================================================================================

-- State, one row per subject per channel, holding the urgency last notified. It is the high-water mark
-- the contract requires: escalation compares against this, never against the previous sample, so a date
-- that moves closer without crossing an edge stays silent.
CREATE TABLE @extschema@.limit_runway_alert (
  channel        text        NOT NULL,
  subject        text        NOT NULL,
  kind           text        NOT NULL,
  object         text        NOT NULL,
  event          text        NOT NULL,
  urgency        integer     NOT NULL,
  notified_at    timestamptz NOT NULL DEFAULT now(),
  notified_count integer     NOT NULL DEFAULT 0,
  PRIMARY KEY (channel, subject)
);

COMMENT ON TABLE @extschema@.limit_runway_alert IS
  'One row per limit per channel, holding the urgency last notified: the high-water mark escalation '
  'compares against, so a condition that moves without crossing an edge stays silent. Managed by '
  'limit_runway_notify(); you should never need to touch it.';

-- The ladder, in one place. A single monotonic number, so escalation is one comparison and the scale
-- can change under it: a row with no rate yet is urgent by the share used, and the same row once it has
-- a date is urgent by the time left. 7 failing now; 6 under a day; 5 under three; 4 under seven; 3 under
-- fifteen; 2 inside the window, which is the onset edge; 0 is nothing worth saying. The numbers are
-- deliberately the same shape as pg_lock_tree's doubling, read backwards: each step is roughly twice as
-- bad as the last, so the notifications stay logarithmic rather than firing on every sample.
CREATE FUNCTION @extschema@.limit_runway_urgency(
  p_rank_class    integer,
  p_until_date    timestamptz,
  p_used_fraction numeric,
  p_within        interval)
RETURNS integer
LANGUAGE sql STABLE
AS $$
  SELECT CASE
    WHEN p_rank_class = 1 THEN 7
    WHEN p_until_date IS NOT NULL THEN
      CASE
        WHEN p_until_date - now() < interval '1 day'     THEN 6
        WHEN p_until_date - now() < interval '3 days'    THEN 5
        WHEN p_until_date - now() < interval '7 days'    THEN 4
        WHEN p_until_date - now() < interval '15 days'   THEN 3
        WHEN p_until_date - now() < p_within             THEN 2
        ELSE 0
      END
    WHEN p_used_fraction IS NOT NULL THEN
      -- Halving the remaining headroom: 0.5 used, 0.75, 0.875. The same geometric idea as the window
      -- ladder, applied to the quantity a peak or a no-rate-yet row actually has an edge in.
      CASE
        WHEN p_used_fraction >= 0.875 THEN 6
        WHEN p_used_fraction >= 0.75  THEN 5
        WHEN p_used_fraction >= 0.5   THEN 4
        ELSE 0
      END
    ELSE 0
  END
$$;

COMMENT ON FUNCTION @extschema@.limit_runway_urgency(integer, timestamptz, numeric, interval) IS
  'The urgency of one finding on one monotonic scale: 7 failing now, 6 under a day, 5 under three, 4 '
  'under seven, 3 under fifteen, 2 inside the window, 0 nothing. A pure function of a finding, so the '
  'ladder lives in one place and both the sender and the resolver read it the same way. A finding the '
  'tool could not establish has no used_fraction and no date, so it is 0: a gap is not an event.';

CREATE FUNCTION @extschema@.limit_runway_notify(
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
    ELSIF u > prev THEN
      -- Materially worse than at the LAST notification, never than the previous sample. A date only
      -- gets closer, so the previous-sample comparison would be true on every sample.
      UPDATE @extschema@.limit_runway_alert
         SET event = 'escalated', urgency = u, notified_at = now(), notified_count = notified_count + 1
       WHERE limit_runway_alert.channel = ch AND limit_runway_alert.subject = subj;
      ev := 'escalated';
    ELSE
      CONTINUE;   -- same severity or better: silent, which is the whole point
    END IF;
    payload := json_build_object(
      'tool', 'pg_limit_runway', 'channel', ch, 'event', ev, 'subject', subj,
      'sampled_at', now(), 'kind', f.kind, 'object', f.object,
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

CREATE FUNCTION @extschema@.limit_runway_notify_resolved(
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
      'sampled_at', now(), 'kind', s.kind, 'object', s.object)::text;
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

REVOKE EXECUTE ON FUNCTION @extschema@.limit_runway_notify(text, interval, numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.limit_runway_notify_resolved(text, interval, numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.limit_runway_urgency(integer, timestamptz, numeric, interval) FROM PUBLIC;
