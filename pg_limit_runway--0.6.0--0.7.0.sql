/* pg_limit_runway--0.6.0--0.7.0.sql
 *
 * 0.7.0 adds limit_runway_rate(kind, object): the 7-day and 24-hour slopes, their disagreement and
 * the date the finding uses. Additive; no existing function's row type changes.
 */
\echo Use "ALTER EXTENSION pg_limit_runway UPDATE TO '0.7.0'" to load this file. \quit


-- -------------------------------------------------------------------------------------------------
-- limit_runway_rate(): the projection with its two slopes and the reason it chose one.
-- -------------------------------------------------------------------------------------------------
-- limit_runway_findings() carries one date and a sentence. This exposes the raw pair: the 7-day and
-- 24-hour slopes, whether they disagree by more than a factor of two, and which one the projection
-- used. New function rather than columns on findings(), because a function's row type cannot be
-- extended without dropping and recreating it.
CREATE FUNCTION @extschema@.limit_runway_rate(p_kind text, p_object text)
RETURNS TABLE (
  kind              text,
  object            text,
  samples           bigint,
  epoch             int,
  segment_start     timestamptz,
  newest_at         timestamptz,
  newest_position   numeric,
  newest_limit      numeric,
  rate_7d           numeric,
  rate_24h          numeric,
  rate_source       text,
  disagree          boolean,
  until_7d          timestamptz,
  until_24h         timestamptz,
  until_date        timestamptz,
  average_gap       interval
)
LANGUAGE sql STABLE
AS $$
  WITH p AS (
    SELECT * FROM @extschema@.limit_runway_projection(p_kind, p_object)
  ),
  f AS (
    SELECT p.*,
           -- The same rule limit_runway_project() uses: more than a factor of two apart, and both
           -- slopes positive, means the reader gets both dates rather than one chosen silently.
           (p.rate_24h IS NOT NULL AND p.rate_7d > 0
            AND (p.rate_24h > 2 * p.rate_7d OR 2 * p.rate_24h < p.rate_7d)) AS disagree
      FROM p
  )
  SELECT p_kind, p_object, f.samples, f.epoch, f.segment_start, f.newest_at,
         f.newest_position, f.newest_limit, f.rate_7d, f.rate_24h,
         CASE WHEN f.samples < 2 OR (f.rate_7d IS NULL AND f.rate_24h IS NULL) THEN 'none'
              WHEN f.rate_7d IS NULL THEN '24-hour'
              WHEN f.rate_24h IS NULL THEN '7-day'
              WHEN f.rate_7d <= 0 AND f.rate_24h <= 0 THEN 'flat'
              WHEN f.disagree THEN 'disagree'
              ELSE 'both' END,
         f.disagree,
         f.until_7d, f.until_24h,
         CASE WHEN f.disagree THEN least(f.until_7d, f.until_24h)
              ELSE coalesce(f.until_7d, f.until_24h) END,
         f.average_gap
    FROM f
$$;

COMMENT ON FUNCTION @extschema@.limit_runway_rate(text, text) IS
  'One series'' projection with both slopes: samples, epoch, segment start, newest observation, the '
  '7-day and 24-hour rates, rate_source (none, 7-day, 24-hour, both, disagree or flat), a disagree '
  'flag using the factor-of-two rule, both projected dates and the date the finding would use. No row '
  'when the series has never been sampled. Read-only.';

REVOKE EXECUTE ON FUNCTION @extschema@.limit_runway_rate(text, text) FROM PUBLIC;

