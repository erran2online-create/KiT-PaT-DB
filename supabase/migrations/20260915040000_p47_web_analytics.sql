-- ---------------------------------------------------------------------------
-- P47: page-view analytics for the kitpat.in marketing site (country,
-- region, city). The marketing visitor has no member JWT, so this cannot
-- go through ingest-event (P45, JWT-required, member-domain event names)
-- -- that function's auth is NOT relaxed. Instead: one new, deliberately
-- narrow event name plus one admin read RPC. The actual anonymous write
-- path is the ingest-web-event edge function (no migration content of its
-- own -- it writes straight to audit_events, already deny-policied
-- against every client role, exactly like ingest-event does).
--
-- public.analytics_event_catalog and public.audit_events were both
-- re-read in full from 20260801140136_remote_schema.sql before writing
-- this (same shapes P45/P45.2 already established): analytics_event_
-- catalog is PK'd on event_name, no CHECK on category; audit_events has
-- no CHECK on source either, so 'web' needs no migration change to be a
-- legal value. audit_events' "deny client audit events" USING(false)
-- policy (both authenticated and anon) is untouched -- it already blocks
-- every client write, which is exactly the guarantee this task relies on.
--
-- ONE grant-level tightening, not a policy or function change (so it
-- stays within "do not change audit_events' policies, or any existing
-- function"): the original baseline dump left GRANT ALL ON audit_events
-- TO anon in place even though "deny client audit events" already blocks
-- every command for anon at the RLS layer -- a stale, redundant grant, the
-- same pattern this session has repeatedly found and flagged elsewhere
-- (flags_admin_write, razorpay_events_admin_only). Revoking it changes no
-- actual behaviour (RLS already made it a no-op) but makes has_table_
-- privilege reflect reality, which this migration's own test relies on.
-- ---------------------------------------------------------------------------
REVOKE ALL ON public.audit_events FROM anon;

-- ---------------------------------------------------------------------------
-- 1. Seed page_view -- category 'website', NEW (the existing nine are
--    activation, games, group, memory, party, retention, virality, kitty,
--    diagnostics; none fits a marketing visit that isn't tied to any
--    member action). ON CONFLICT (event_name) DO NOTHING: safe to re-run,
--    never overwrites an existing row.
-- ---------------------------------------------------------------------------
INSERT INTO public.analytics_event_catalog (event_name, category, description, required_properties, contains_pii)
VALUES (
  'page_view', 'website',
  'A visit to a page on the kitpat.in marketing site. Carries which page (route) and a coarse location (country, region, city) -- never anything that identifies the visitor personally.',
  ARRAY['route', 'country'], false
)
ON CONFLICT (event_name) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. admin_web_analytics -- any active admin. Grouped rollup of page_view
--    rows by country/region/city/route, ordered by count desc (busiest
--    combination first). p_from/p_to are optional, inclusive, compared as
--    UTC dates -- same convention as AP12's admin_ai_usage_summary.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_web_analytics(p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS TABLE (
  country text,
  region text,
  city text,
  route text,
  count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  RETURN QUERY
  SELECT
    a.properties ->> 'country' AS country,
    a.properties ->> 'region' AS region,
    a.properties ->> 'city' AS city,
    a.properties ->> 'route' AS route,
    count(*) AS count
  FROM public.audit_events a
  WHERE a.event_name = 'page_view'
    AND a.source = 'web'
    AND (p_from IS NULL OR (a.occurred_at AT TIME ZONE 'UTC')::date >= p_from)
    AND (p_to IS NULL OR (a.occurred_at AT TIME ZONE 'UTC')::date <= p_to)
  GROUP BY a.properties ->> 'country', a.properties ->> 'region', a.properties ->> 'city', a.properties ->> 'route'
  ORDER BY count DESC;
END;
$$;

COMMENT ON FUNCTION public.admin_web_analytics(date, date) IS
  'Any active admin. Grouped rollup (country, region, city, route, count) of ingest-web-event''s page_view rows in audit_events, optionally UTC-date-bounded (inclusive), ordered by count desc. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_web_analytics(date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_web_analytics(date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_web_analytics(date, date) TO authenticated, service_role;
