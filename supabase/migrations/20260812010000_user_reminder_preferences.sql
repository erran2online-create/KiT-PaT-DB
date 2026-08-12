-- P15: User-configurable reminder frequency + active hours window.
-- Diagnosis (P12.2): DB mark/RPC were correct, but n8n did not reload the
-- published workflow after import ("Changes will not take effect if n8n is
-- running"), so the live cron kept the old no-mark 24h workflow and re-sent
-- hourly while the event stayed in the window.

-- ---------------------------------------------------------------------------
-- Preferences
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_reminder_preferences (
  user_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  frequency text NOT NULL DEFAULT 'once_daily'
    CHECK (frequency = ANY (ARRAY[
      'once_daily'::text,
      'twice_daily'::text,
      'thrice_daily'::text,
      'hourly'::text
    ])),
  preferred_time time without time zone,
  active_window_start time without time zone NOT NULL DEFAULT TIME '06:00',
  active_window_end time without time zone NOT NULL DEFAULT TIME '21:00',
  timezone text NOT NULL DEFAULT 'Asia/Kolkata',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_reminder_preferences_window_check
    CHECK (active_window_start < active_window_end)
);

COMMENT ON TABLE public.user_reminder_preferences IS
  'Per-user reminder cadence and quiet hours (local timezone).';

CREATE TABLE IF NOT EXISTS public.user_reminder_sends (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  local_date date NOT NULL,
  slot_index integer NOT NULL CHECK (slot_index >= 0),
  sent_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, local_date, slot_index)
);

COMMENT ON TABLE public.user_reminder_sends IS
  'Idempotent send ledger for preference-based digests (one row per local-day slot).';

CREATE INDEX IF NOT EXISTS idx_user_reminder_sends_user_day
  ON public.user_reminder_sends (user_id, local_date);

ALTER TABLE public.user_reminder_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_reminder_sends ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_reminder_preferences_own ON public.user_reminder_preferences;
CREATE POLICY user_reminder_preferences_own ON public.user_reminder_preferences
  FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid()))
  WITH CHECK (user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS user_reminder_sends_own ON public.user_reminder_sends;
CREATE POLICY user_reminder_sends_own ON public.user_reminder_sends
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_reminder_preferences
  TO authenticated, service_role;
GRANT SELECT, INSERT ON public.user_reminder_sends
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._reminder_slots_per_day(p_frequency text)
RETURNS integer
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE p_frequency
    WHEN 'once_daily' THEN 1
    WHEN 'twice_daily' THEN 2
    WHEN 'thrice_daily' THEN 3
    WHEN 'hourly' THEN NULL  -- computed from window length
    ELSE 1
  END;
$$;

CREATE OR REPLACE FUNCTION public.get_users_due_for_reminder(
  p_now timestamptz DEFAULT now()
)
RETURNS TABLE (
  user_id uuid,
  user_name text,
  telegram_id text,
  frequency text,
  timezone text,
  local_time time,
  local_date date,
  slot_index integer,
  slots_today integer,
  active_window_start time,
  active_window_end time,
  upcoming_event_id uuid,
  upcoming_event_title text,
  upcoming_party_date timestamptz,
  group_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  ts timestamptz := coalesce(p_now, now());
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  RETURN QUERY
  WITH prefs AS (
    SELECT
      u.id AS uid,
      u.name AS uname,
      u.telegram_id AS tg,
      coalesce(p.frequency, 'once_daily') AS freq,
      coalesce(p.timezone, 'Asia/Kolkata') AS tz,
      coalesce(p.preferred_time, TIME '09:00') AS pref_time,
      coalesce(p.active_window_start, TIME '06:00') AS win_start,
      coalesce(p.active_window_end, TIME '21:00') AS win_end
    FROM public.users u
    LEFT JOIN public.user_reminder_preferences p ON p.user_id = u.id
    WHERE coalesce(u.notifications_enabled, true) = true
  ),
  local_ctx AS (
    SELECT
      pr.*,
      (ts AT TIME ZONE pr.tz)::date AS loc_date,
      (ts AT TIME ZONE pr.tz)::time AS loc_time,
      EXTRACT(EPOCH FROM (
        ((ts AT TIME ZONE pr.tz)::date + pr.win_end)
        - ((ts AT TIME ZONE pr.tz)::date + pr.win_start)
      ))::integer / 60 AS window_minutes
    FROM prefs pr
  ),
  slotted AS (
    SELECT
      lc.*,
      CASE
        WHEN lc.freq = 'hourly' THEN
          GREATEST(1, (lc.window_minutes / 60))
        ELSE
          public._reminder_slots_per_day(lc.freq)
      END AS n_slots,
      CASE
        -- Outside active window → never due
        WHEN lc.loc_time < lc.win_start OR lc.loc_time >= lc.win_end THEN NULL
        WHEN lc.freq = 'once_daily' THEN
          -- Due once after preferred_time (clamped into window)
          CASE
            WHEN lc.loc_time < GREATEST(lc.pref_time, lc.win_start) THEN NULL
            ELSE 0
          END
        WHEN lc.freq = 'hourly' THEN
          -- One slot per hour inside the window
          FLOOR(EXTRACT(EPOCH FROM (lc.loc_time - lc.win_start)) / 3600.0)::integer
        ELSE
          -- twice/thrice: equal slices across the window
          LEAST(
            public._reminder_slots_per_day(lc.freq) - 1,
            FLOOR(
              EXTRACT(EPOCH FROM (lc.loc_time - lc.win_start)) / 60.0
              / NULLIF(
                  lc.window_minutes::numeric / public._reminder_slots_per_day(lc.freq),
                  0
                )
            )::integer
          )
      END AS slot_idx
    FROM local_ctx lc
  ),
  due_users AS (
    SELECT s.*
    FROM slotted s
    WHERE s.slot_idx IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.user_reminder_sends urs
        WHERE urs.user_id = s.uid
          AND urs.local_date = s.loc_date
          AND urs.slot_index = s.slot_idx
      )
  ),
  -- Upcoming party context: RSVP going/maybe on scheduled/live events
  upcoming AS (
    SELECT DISTINCT ON (r.user_id)
      r.user_id AS uid,
      e.id AS event_id,
      e.title AS event_title,
      e.party_date,
      g.name AS gname
    FROM public.rsvp r
    JOIN public.events e ON e.id = r.event_id
    JOIN public.groups g ON g.id = e.group_id
    WHERE r.status IN ('going', 'maybe')
      AND e.status IN ('scheduled', 'live')
      AND e.party_date IS NOT NULL
      AND e.party_date >= ts - interval '1 hour'
      AND e.party_date < ts + interval '7 days'
    ORDER BY r.user_id, e.party_date ASC
  )
  SELECT
    d.uid,
    d.uname,
    d.tg,
    d.freq,
    d.tz,
    d.loc_time,
    d.loc_date,
    d.slot_idx,
    d.n_slots,
    d.win_start,
    d.win_end,
    u.event_id,
    u.event_title,
    u.party_date,
    u.gname
  FROM due_users d
  JOIN upcoming u ON u.uid = d.uid
  ORDER BY d.uid;
END;
$$;

COMMENT ON FUNCTION public.get_users_due_for_reminder(timestamptz) IS
  'n8n: users due for a preference-based reminder now (respects frequency + 6am–9pm-style active window). p_now overrides clock for tests.';

REVOKE ALL ON FUNCTION public.get_users_due_for_reminder(timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_users_due_for_reminder(timestamptz)
  TO service_role, authenticated;

CREATE OR REPLACE FUNCTION public.n8n_mark_user_reminder_sent(
  p_user_id uuid,
  p_slot_index integer,
  p_now timestamptz DEFAULT now()
) RETURNS public.user_reminder_sends
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  tz text;
  loc_date date;
  row public.user_reminder_sends;
  ts timestamptz := coalesce(p_now, now());
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_user_id IS NULL OR p_slot_index IS NULL OR p_slot_index < 0 THEN
    RAISE EXCEPTION 'user_id and non-negative slot_index required';
  END IF;

  SELECT coalesce(p.timezone, 'Asia/Kolkata') INTO tz
  FROM public.user_reminder_preferences p
  WHERE p.user_id = p_user_id;
  tz := coalesce(tz, 'Asia/Kolkata');
  loc_date := (ts AT TIME ZONE tz)::date;

  INSERT INTO public.user_reminder_sends (user_id, local_date, slot_index, sent_at)
  VALUES (p_user_id, loc_date, p_slot_index, ts)
  ON CONFLICT (user_id, local_date, slot_index)
  DO UPDATE SET sent_at = EXCLUDED.sent_at
  RETURNING * INTO row;

  RETURN row;
END;
$$;

COMMENT ON FUNCTION public.n8n_mark_user_reminder_sent(uuid, integer, timestamptz) IS
  'n8n: record a preference-slot reminder send (idempotent per user/local_date/slot).';

REVOKE ALL ON FUNCTION public.n8n_mark_user_reminder_sent(uuid, integer, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.n8n_mark_user_reminder_sent(uuid, integer, timestamptz)
  TO service_role, authenticated;

-- Seed default prefs for existing users (once_daily, 06:00–21:00 IST)
INSERT INTO public.user_reminder_preferences (user_id, frequency, preferred_time, timezone)
SELECT u.id, 'once_daily', TIME '09:00', 'Asia/Kolkata'
FROM public.users u
ON CONFLICT (user_id) DO NOTHING;
