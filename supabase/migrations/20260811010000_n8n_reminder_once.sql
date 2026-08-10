-- P12.2: Send 24h party reminder once per event (not every hourly cron tick).
-- Uses existing public.sent_reminders (event_id, user_id, timing).

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
    AND e.party_date >= now() - interval '1 hour'
    AND e.party_date < now() + interval '24 hours'
    -- Already sent a 24h reminder for this event (any recipient row counts)
    AND NOT EXISTS (
      SELECT 1
      FROM public.sent_reminders sr
      WHERE sr.event_id = e.id
        AND sr.timing = '24h'
    )
  ORDER BY e.party_date ASC;
END;
$$;

COMMENT ON FUNCTION public.n8n_events_due_in_24h() IS
  'n8n: events in ~24h window that have not yet received a timing=24h reminder.';

CREATE OR REPLACE FUNCTION public.n8n_mark_reminder_sent(
  p_event_id uuid,
  p_timing text DEFAULT '24h'
) RETURNS public.sent_reminders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  ev public.events;
  marker_user uuid;
  row public.sent_reminders;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_event_id IS NULL THEN
    RAISE EXCEPTION 'event_id required';
  END IF;
  IF p_timing IS NULL OR p_timing NOT IN ('24h', 'morning', '1h') THEN
    RAISE EXCEPTION 'timing must be 24h, morning, or 1h';
  END IF;

  SELECT * INTO ev FROM public.events WHERE id = p_event_id;
  IF ev.id IS NULL THEN
    RAISE EXCEPTION 'Event not found';
  END IF;

  -- Event-level digest marker: one row keyed by host/creator + timing.
  marker_user := coalesce(ev.created_by, (
    SELECT g.host_id FROM public.groups g WHERE g.id = ev.group_id
  ));
  IF marker_user IS NULL THEN
    RAISE EXCEPTION 'Event has no created_by/host to record reminder';
  END IF;

  INSERT INTO public.sent_reminders (event_id, user_id, timing, sent_at)
  VALUES (p_event_id, marker_user, p_timing, now())
  ON CONFLICT (event_id, user_id, timing)
  DO UPDATE SET sent_at = EXCLUDED.sent_at
  RETURNING * INTO row;

  RETURN row;
END;
$$;

COMMENT ON FUNCTION public.n8n_mark_reminder_sent(uuid, text) IS
  'n8n: record that a reminder digest was sent for an event (idempotent).';

REVOKE ALL ON FUNCTION public.n8n_mark_reminder_sent(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.n8n_mark_reminder_sent(uuid, text)
  TO service_role, authenticated;

-- Stop ongoing spam for events already in the 24h window that were messaged
-- before this fix (mark via creator so the RPC stops returning them).
INSERT INTO public.sent_reminders (event_id, user_id, timing, sent_at)
SELECT e.id, e.created_by, '24h', now()
FROM public.events e
WHERE e.status IN ('scheduled', 'live')
  AND e.party_date IS NOT NULL
  AND e.party_date >= now() - interval '1 hour'
  AND e.party_date < now() + interval '24 hours'
  AND e.created_by IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.sent_reminders sr
    WHERE sr.event_id = e.id AND sr.timing = '24h'
  )
ON CONFLICT (event_id, user_id, timing) DO NOTHING;
