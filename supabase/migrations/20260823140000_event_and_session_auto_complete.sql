-- Auto-complete stale events/game sessions: parties and game sessions never
-- transitioned out of their initial state on their own, so recap generation,
-- memory artifacts and badge awarding never fired for anything that wasn't
-- manually closed out by a host in the app.
--
-- Confirmed live state before writing this (not re-queried; no DB access):
--   events: only status='scheduled' currently in use, 4 open events, 3 of
--     them with party_date > 6h in the past.
--   game_sessions: active/cancelled/completed/lobby/paused in use, 2 active
--     sessions with updated_at > 4h in the past.
--   generate_party_recap and check_and_award_badges already exist.
--   complete_event and events.completed_at do NOT exist yet.
--
-- This migration:
--   1. events.completed_at (nullable, additive) + complete_event(p_event_id)
--      — host-only manual close: sets status='completed' + completed_at,
--      then runs recap + badge-award for every attendee in the same
--      transaction. Stable codes: KITPAT_UNAUTHENTICATED / KITPAT_NOT_FOUND /
--      KITPAT_NOT_HOST / KITPAT_ALREADY_COMPLETED.
--   2. auto_complete_stale_events() — the same close-out, automatically, for
--      any event with party_date < now() - 6h still sitting in
--      'scheduled'/'draft'. Scheduled hourly via pg_cron.
--   3. auto_close_stale_game_sessions() — any 'active' game_sessions row
--      with updated_at < now() - 4h is force-completed; a game_events row
--      logs the auto-close with a final-scores snapshot read from
--      game_players (there is no separate scores column on game_sessions to
--      write to, so the snapshot lives in the audit row, which this
--      requirement calls for anyway). Scheduled hourly via pg_cron.
--   4/5. Backfill + confirmation queries are NOT executed by this file (no
--      live DB access from this session) — see the reviewer-run block at
--      the bottom of this file.
--
-- Auth for the two automatic paths: neither runs with a real caller session,
-- so both generate_party_recap and check_and_award_badges (which gate on
-- auth.uid()/auth.role()) would otherwise reject them. generate_party_recap
-- already has a service_role bypass built in (P12, for exactly this n8n/cron
-- case), so the recap call impersonates service_role via
-- set_config('request.jwt.claims', ...). check_and_award_badges instead
-- authorizes "the subject user checking their own badges" with no special
-- case needed — the badge-award loop impersonates each attendee as
-- themselves for the duration of their own call, which satisfies that
-- function's existing rule unmodified. Neither existing function is altered.
--
-- Additive only: one new nullable column, three new functions (one of them
-- host-gated and directly callable, two internal/cron-only), two pg_cron
-- schedules. No existing row's value changes except via the explicit,
-- reviewer-run backfill described below.

-- ---------------------------------------------------------------------------
-- 1. events.completed_at
-- ---------------------------------------------------------------------------
ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS completed_at timestamptz;

COMMENT ON COLUMN public.events.completed_at IS
  'Set by complete_event() / auto_complete_stale_events() when status transitions to completed. NULL until then.';

-- ---------------------------------------------------------------------------
-- 2. complete_event — host-only manual close
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.complete_event(
  p_event_id uuid
) RETURNS public.events
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  ev public.events;
  attendee record;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;

  SELECT * INTO ev FROM public.events WHERE id = p_event_id FOR UPDATE;
  IF ev.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
  IF NOT public.is_group_host(ev.group_id, uid) THEN
    RAISE EXCEPTION 'KITPAT_NOT_HOST' USING ERRCODE = 'PT403';
  END IF;
  IF ev.status = 'completed' THEN
    RAISE EXCEPTION 'KITPAT_ALREADY_COMPLETED' USING ERRCODE = 'PT409';
  END IF;

  UPDATE public.events
  SET status = 'completed',
      completed_at = now(),
      updated_at = now()
  WHERE id = ev.id
  RETURNING * INTO ev;

  PERFORM public.generate_party_recap(ev.id);

  FOR attendee IN
    SELECT DISTINCT a.user_id FROM public.attendance a WHERE a.event_id = ev.id
  LOOP
    -- Impersonate the attendee for the duration of their own badge check;
    -- check_and_award_badges already authorizes "subject user checking
    -- their own badges" with no changes needed to that function.
    PERFORM set_config(
      'request.jwt.claims',
      jsonb_build_object('sub', attendee.user_id::text, 'role', 'authenticated')::text,
      true
    );
    PERFORM public.check_and_award_badges(attendee.user_id, ev.group_id);
  END LOOP;

  -- Restore the real caller's identity for the remainder of this transaction.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', uid::text, 'role', 'authenticated')::text,
    true
  );

  RETURN ev;
END;
$$;

COMMENT ON FUNCTION public.complete_event(uuid) IS
  'Host-only. Closes an event: status=completed, completed_at=now(), then generates the party recap and runs badge-award for every attendee, all in one transaction. Errors: KITPAT_UNAUTHENTICATED / KITPAT_NOT_FOUND / KITPAT_NOT_HOST / KITPAT_ALREADY_COMPLETED.';

-- ---------------------------------------------------------------------------
-- 3. auto_complete_stale_events — cron: events stuck open past their date
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_complete_stale_events() RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  ev record;
  attendee record;
  n integer := 0;
BEGIN
  FOR ev IN
    SELECT e.id, e.group_id
    FROM public.events e
    WHERE e.party_date IS NOT NULL
      AND e.party_date < now() - interval '6 hours'
      AND e.status IN ('scheduled', 'draft')
    FOR UPDATE OF e
  LOOP
    UPDATE public.events
    SET status = 'completed',
        completed_at = now(),
        updated_at = now()
    WHERE id = ev.id;

    -- No real caller here: impersonate service_role, which
    -- generate_party_recap already trusts to regenerate freely (P12).
    PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'service_role')::text, true);
    PERFORM public.generate_party_recap(ev.id);

    FOR attendee IN
      SELECT DISTINCT a.user_id FROM public.attendance a WHERE a.event_id = ev.id
    LOOP
      PERFORM set_config(
        'request.jwt.claims',
        jsonb_build_object('sub', attendee.user_id::text, 'role', 'authenticated')::text,
        true
      );
      PERFORM public.check_and_award_badges(attendee.user_id, ev.group_id);
    END LOOP;

    n := n + 1;
  END LOOP;

  -- No real caller identity to restore; leave the session unauthenticated.
  PERFORM set_config('request.jwt.claims', '{}', true);

  RETURN n;
END;
$$;

COMMENT ON FUNCTION public.auto_complete_stale_events() IS
  'Cron (hourly). Force-completes any scheduled/draft event whose party_date is more than 6h in the past: status=completed, completed_at=now(), then recap + badge-award for every attendee, same as complete_event(). Returns the number of events closed.';

-- ---------------------------------------------------------------------------
-- 4. auto_close_stale_game_sessions — cron: sessions stuck active
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_close_stale_game_sessions() RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s record;
  final_scores jsonb;
  n integer := 0;
BEGIN
  FOR s IN
    SELECT gs.id
    FROM public.game_sessions gs
    WHERE gs.status = 'active'
      AND gs.updated_at < now() - interval '4 hours'
    FOR UPDATE OF gs
  LOOP
    SELECT coalesce(
             jsonb_agg(
               jsonb_build_object('user_id', gp.user_id, 'score', gp.score)
               ORDER BY gp.score DESC
             ),
             '[]'::jsonb
           )
      INTO final_scores
    FROM public.game_players gp
    WHERE gp.session_id = s.id;

    UPDATE public.game_sessions
    SET status = 'completed',
        ended_at = now(),
        updated_at = now()
    WHERE id = s.id;

    INSERT INTO public.game_events (session_id, event_type, actor_id, payload)
    VALUES (
      s.id,
      'auto_closed',
      NULL,
      jsonb_build_object(
        'reason', 'stale_active_session_auto_closed',
        'closed_at', now(),
        'final_scores', final_scores
      )
    );

    n := n + 1;
  END LOOP;

  RETURN n;
END;
$$;

COMMENT ON FUNCTION public.auto_close_stale_game_sessions() IS
  'Cron (hourly). Force-completes any active game_sessions row whose updated_at is more than 4h in the past: status=completed, ended_at=now(), and logs a game_events row (event_type=auto_closed) with a final-scores snapshot read from game_players. Returns the number of sessions closed.';

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.complete_event(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.auto_complete_stale_events() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.auto_close_stale_game_sessions() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.complete_event(uuid) TO authenticated, service_role;
-- The two auto_* functions are cron/ops-only: no end user ever calls these
-- directly, so authenticated does not get EXECUTE.
GRANT EXECUTE ON FUNCTION public.auto_complete_stale_events() TO service_role;
GRANT EXECUTE ON FUNCTION public.auto_close_stale_game_sessions() TO service_role;

-- ---------------------------------------------------------------------------
-- 6. pg_cron schedules — hourly
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

DO $$
DECLARE existing bigint;
BEGIN
  SELECT j.jobid INTO existing FROM cron.job j WHERE j.jobname = 'auto-complete-stale-events' LIMIT 1;
  IF existing IS NOT NULL THEN
    PERFORM cron.unschedule(existing);
  END IF;

  PERFORM cron.schedule(
    'auto-complete-stale-events',
    '0 * * * *',
    $cron$SELECT public.auto_complete_stale_events();$cron$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule auto-complete-stale-events cron job: %', sqlerrm;
END;
$$;

DO $$
DECLARE existing bigint;
BEGIN
  SELECT j.jobid INTO existing FROM cron.job j WHERE j.jobname = 'auto-close-stale-game-sessions' LIMIT 1;
  IF existing IS NOT NULL THEN
    PERFORM cron.unschedule(existing);
  END IF;

  PERFORM cron.schedule(
    'auto-close-stale-game-sessions',
    '0 * * * *',
    $cron$SELECT public.auto_close_stale_game_sessions();$cron$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule auto-close-stale-game-sessions cron job: %', sqlerrm;
END;
$$;

-- ---------------------------------------------------------------------------
-- 7. REVIEWER-RUN ONLY — nothing below this line executes automatically.
--    This migration deliberately does not call the backfill itself; run
--    these by hand after `supabase db push` applies the migration above.
-- ---------------------------------------------------------------------------

-- 7a. One-time backfill over the currently-stale rows (4 open events, 3 of
--     them stale; 2 stale active game sessions, per the confirmed live
--     state). Also reports badges awarded as a side effect of the event
--     backfill. Safe to re-run: the second run will simply close 0/0 once
--     nothing remains stale.
--
-- WITH before AS MATERIALIZED (SELECT count(*) AS n FROM public.member_badges),
--      events_closed AS MATERIALIZED (SELECT public.auto_complete_stale_events() AS n),
--      sessions_closed AS MATERIALIZED (SELECT public.auto_close_stale_game_sessions() AS n),
--      after AS MATERIALIZED (SELECT count(*) AS n FROM public.member_badges)
-- SELECT
--   (SELECT n FROM events_closed)   AS events_closed,
--   (SELECT n FROM sessions_closed) AS sessions_closed,
--   (SELECT n FROM after) - (SELECT n FROM before) AS badges_awarded;

-- 7b. Confirm the n8n polling RPC still sees the right rows afterwards
--     (any of the just-closed events whose recap failed to generate would
--     show up here; a healthy backfill should leave this empty or close to
--     it since complete_event()/auto_complete_stale_events() both generate
--     the recap in the same transaction as the status flip):
--
-- SELECT * FROM public.n8n_events_needing_recap();
