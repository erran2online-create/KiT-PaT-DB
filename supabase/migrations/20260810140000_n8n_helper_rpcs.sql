-- P12: thin helper RPCs for n8n scheduling (service_role only).
-- No game/money/claim logic — just event selection for messaging.

CREATE OR REPLACE FUNCTION public.n8n_events_due_in_24h()
RETURNS TABLE (
  id uuid,
  group_id uuid,
  title text,
  theme text,
  venue text,
  party_date timestamptz,
  contribution_amount integer,
  status text,
  group_name text,
  rsvp_going_maybe integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  -- Prefer service_role; allow authenticated hosts for manual testing.
  IF auth.role() IS DISTINCT FROM 'service_role' AND auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  RETURN QUERY
  SELECT
    e.id,
    e.group_id,
    e.title,
    e.theme,
    e.venue,
    e.party_date,
    e.contribution_amount,
    e.status,
    g.name AS group_name,
    (
      SELECT count(*)::integer
      FROM public.rsvp r
      WHERE r.event_id = e.id
        AND r.status IN ('going', 'maybe')
    ) AS rsvp_going_maybe
  FROM public.events e
  JOIN public.groups g ON g.id = e.group_id
  WHERE e.status IN ('scheduled', 'live')
    AND e.party_date IS NOT NULL
    -- Within the next 24 hours (and not already started more than 1h ago)
    AND e.party_date >= now() - interval '1 hour'
    AND e.party_date < now() + interval '24 hours'
  ORDER BY e.party_date ASC;
END;
$$;

COMMENT ON FUNCTION public.n8n_events_due_in_24h() IS
  'n8n: events starting within ~24h for reminder digests.';

REVOKE ALL ON FUNCTION public.n8n_events_due_in_24h() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.n8n_events_due_in_24h()
  TO service_role, authenticated;

CREATE OR REPLACE FUNCTION public.n8n_events_needing_recap()
RETURNS TABLE (
  id uuid,
  group_id uuid,
  title text,
  party_date timestamptz,
  status text,
  group_name text,
  has_recap boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  RETURN QUERY
  SELECT
    e.id,
    e.group_id,
    e.title,
    e.party_date,
    e.status,
    g.name AS group_name,
    EXISTS (
      SELECT 1
      FROM public.memory_artifacts ma
      WHERE ma.event_id = e.id
        AND ma.artifact_type = 'party_recap'
    ) AS has_recap
  FROM public.events e
  JOIN public.groups g ON g.id = e.group_id
  WHERE e.status = 'completed'
    AND e.party_date IS NOT NULL
    -- Recently completed window (48h) so polling stays cheap
    AND e.party_date >= now() - interval '48 hours'
    AND NOT EXISTS (
      SELECT 1
      FROM public.memory_artifacts ma
      WHERE ma.event_id = e.id
        AND ma.artifact_type = 'party_recap'
    )
  ORDER BY e.party_date DESC;
END;
$$;

COMMENT ON FUNCTION public.n8n_events_needing_recap() IS
  'n8n: completed events in last 48h missing a party_recap artifact.';

REVOKE ALL ON FUNCTION public.n8n_events_needing_recap() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.n8n_events_needing_recap()
  TO service_role, authenticated;
