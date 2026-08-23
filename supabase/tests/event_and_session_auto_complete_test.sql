-- Test: complete_event / auto_complete_stale_events / auto_close_stale_game_sessions.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the migration
-- (20260823140000_event_and_session_auto_complete.sql) applied. No fixture
-- row survives past the ROLLBACK — nothing to clean up by hand.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/event_and_session_auto_complete_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. complete_event (host-only, manual): status -> completed,
--      completed_at set, a party_recap memory_artifacts row appears, the
--      attendee's badge is awarded. Also: KITPAT_ALREADY_COMPLETED on a
--      second call, KITPAT_NOT_HOST for a non-host, KITPAT_NOT_FOUND for an
--      unknown id, KITPAT_UNAUTHENTICATED with no session.
--   2. auto_complete_stale_events(): a fixture event dated 8 hours ago,
--      still 'scheduled', is force-completed with the same recap + badge
--      treatment, independent of and in addition to (1).
--   3. auto_close_stale_game_sessions(): a fixture 'active' session last
--      updated 5 hours ago is force-completed, ended_at set, and a
--      game_events row logs the auto-close with a final_scores snapshot
--      matching game_players.

BEGIN;

DO $t$
DECLARE
  u_host uuid := gen_random_uuid();
  u_a    uuid := gen_random_uuid();
  u_b    uuid := gen_random_uuid();
  g_id   uuid := gen_random_uuid();
  v_badge_id uuid;
  ev_manual uuid;
  ev_stale  uuid;
  v_session_id uuid;
  ev_row public.events;
  err text;
  n integer;
  artifact_count integer;
  badge_count integer;
  session_row public.game_sessions;
  ge_payload jsonb;

BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (id, name, phone) VALUES
    (u_host, 'Auto-Complete Host', '+910000000940'),
    (u_a,    'Auto-Complete A',    '+910000000941'),
    (u_b,    'Auto-Complete B',    '+910000000942');

  INSERT INTO public.groups (id, name, host_id) VALUES
    (g_id, 'Auto-Complete Test Group', u_host);

  INSERT INTO public.members (group_id, user_id, role, streak_count) VALUES
    (g_id, u_a, 'member', 6),
    (g_id, u_b, 'member', 6)
  ON CONFLICT (group_id, user_id) DO UPDATE SET streak_count = 6;

  INSERT INTO public.badge_definitions (name, description, emoji, category, auto_rule, is_host_assigned)
  VALUES ('Test Streak Badge', 'fixture for auto-complete test', '🔥', 'attendance', 'streak_count >= 6', false)
  RETURNING id INTO v_badge_id;

  -- Not stale: will be completed manually via complete_event().
  INSERT INTO public.events (group_id, theme, party_date, status, created_by)
  VALUES (g_id, 'birthday', now(), 'scheduled', u_host)
  RETURNING id INTO ev_manual;

  -- Stale: 8 hours past party_date, still scheduled, for the cron path.
  INSERT INTO public.events (group_id, theme, party_date, status, created_by)
  VALUES (g_id, 'anniversary', now() - interval '8 hours', 'scheduled', u_host)
  RETURNING id INTO ev_stale;

  INSERT INTO public.attendance (event_id, user_id) VALUES
    (ev_manual, u_a),
    (ev_stale, u_b);

  ------------------------------------------------------- 1. complete_event()
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);
  ev_row := public.complete_event(ev_manual);

  IF ev_row.status <> 'completed' THEN
    RAISE EXCEPTION 'FAIL: complete_event status = %, expected completed', ev_row.status;
  END IF;
  IF ev_row.completed_at IS NULL THEN
    RAISE EXCEPTION 'FAIL: complete_event did not set completed_at';
  END IF;

  SELECT count(*) INTO artifact_count
  FROM public.memory_artifacts
  WHERE event_id = ev_manual AND artifact_type = 'party_recap';
  IF artifact_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected exactly 1 party_recap memory_artifacts row for ev_manual, found %', artifact_count;
  END IF;

  SELECT count(*) INTO badge_count
  FROM public.member_badges
  WHERE user_id = u_a AND group_id = g_id AND badge_id = v_badge_id;
  IF badge_count < 1 THEN
    RAISE EXCEPTION 'FAIL: expected at least 1 badge awarded to u_a after complete_event, found %', badge_count;
  END IF;
  RAISE NOTICE 'PASS: complete_event flips status, sets completed_at, generates a party_recap artifact, awards the attendee''s badge';

  -- Already completed.
  BEGIN
    PERFORM public.complete_event(ev_manual);
    RAISE EXCEPTION 'FAIL: complete_event allowed completing an already-completed event';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ALREADY_COMPLETED' THEN
      RAISE EXCEPTION 'FAIL: re-complete raised "%", expected KITPAT_ALREADY_COMPLETED', err;
    END IF;
  END;

  -- Non-host.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.complete_event(ev_stale);
    RAISE EXCEPTION 'FAIL: a non-host was allowed to complete an event';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_HOST' THEN
      RAISE EXCEPTION 'FAIL: non-host complete_event raised "%", expected KITPAT_NOT_HOST', err;
    END IF;
  END;

  -- Unknown event.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.complete_event(gen_random_uuid());
    RAISE EXCEPTION 'FAIL: complete_event accepted an unknown event id';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_FOUND' THEN
      RAISE EXCEPTION 'FAIL: unknown event raised "%", expected KITPAT_NOT_FOUND', err;
    END IF;
  END;

  -- No session at all.
  PERFORM set_config('request.jwt.claims', '{}', true);
  BEGIN
    PERFORM public.complete_event(ev_stale);
    RAISE EXCEPTION 'FAIL: complete_event was callable with no authenticated session';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_UNAUTHENTICATED' THEN
      RAISE EXCEPTION 'FAIL: unauthenticated call raised "%", expected KITPAT_UNAUTHENTICATED', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: KITPAT_ALREADY_COMPLETED / KITPAT_NOT_HOST / KITPAT_NOT_FOUND / KITPAT_UNAUTHENTICATED all raised correctly';

  ------------------------------------------------- 2. auto_complete_stale_events()
  -- Confirm ev_stale really is still open and 8h stale before running it.
  IF (SELECT status FROM public.events WHERE id = ev_stale) <> 'scheduled' THEN
    RAISE EXCEPTION 'FAIL: test setup broken — ev_stale is not scheduled before the cron call';
  END IF;

  n := public.auto_complete_stale_events();
  IF n < 1 THEN
    RAISE EXCEPTION 'FAIL: auto_complete_stale_events reported % events closed, expected at least 1', n;
  END IF;

  SELECT * INTO ev_row FROM public.events WHERE id = ev_stale;
  IF ev_row.status <> 'completed' THEN
    RAISE EXCEPTION 'FAIL: ev_stale status = % after auto_complete_stale_events, expected completed', ev_row.status;
  END IF;
  IF ev_row.completed_at IS NULL THEN
    RAISE EXCEPTION 'FAIL: ev_stale completed_at is null after auto_complete_stale_events';
  END IF;

  SELECT count(*) INTO artifact_count
  FROM public.memory_artifacts
  WHERE event_id = ev_stale AND artifact_type = 'party_recap';
  IF artifact_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: expected exactly 1 party_recap memory_artifacts row for ev_stale, found %', artifact_count;
  END IF;

  SELECT count(*) INTO badge_count
  FROM public.member_badges
  WHERE user_id = u_b AND group_id = g_id AND badge_id = v_badge_id;
  IF badge_count < 1 THEN
    RAISE EXCEPTION 'FAIL: expected at least 1 badge awarded to u_b after auto_complete_stale_events, found %', badge_count;
  END IF;
  RAISE NOTICE 'PASS: auto_complete_stale_events force-completes an 8h-stale event, generates its recap, and awards its attendee''s badge';

  ------------------------------------------ 3. auto_close_stale_game_sessions()
  INSERT INTO public.game_sessions (event_id, group_id, game_type, host_id, status, updated_at)
  VALUES (ev_stale, g_id, 'tambola', u_host, 'active', now() - interval '5 hours')
  RETURNING id INTO v_session_id;

  INSERT INTO public.game_players (session_id, user_id, score) VALUES
    (v_session_id, u_a, 42),
    (v_session_id, u_b, 17);

  n := public.auto_close_stale_game_sessions();
  IF n < 1 THEN
    RAISE EXCEPTION 'FAIL: auto_close_stale_game_sessions reported % sessions closed, expected at least 1', n;
  END IF;

  SELECT * INTO session_row FROM public.game_sessions WHERE id = v_session_id;
  IF session_row.status <> 'completed' THEN
    RAISE EXCEPTION 'FAIL: session status = % after auto_close_stale_game_sessions, expected completed', session_row.status;
  END IF;
  IF session_row.ended_at IS NULL THEN
    RAISE EXCEPTION 'FAIL: session ended_at is null after auto_close_stale_game_sessions';
  END IF;

  SELECT payload INTO ge_payload
  FROM public.game_events
  WHERE session_id = v_session_id AND event_type = 'auto_closed'
  ORDER BY created_at DESC
  LIMIT 1;
  IF ge_payload IS NULL THEN
    RAISE EXCEPTION 'FAIL: no auto_closed game_events row was logged for the stale session';
  END IF;
  IF (
    SELECT (elem->>'score')::integer
    FROM jsonb_array_elements(ge_payload->'final_scores') elem
    WHERE (elem->>'user_id')::uuid = u_a
  ) <> 42 THEN
    RAISE EXCEPTION 'FAIL: game_events final_scores payload missing/wrong score for u_a: %', ge_payload::text;
  END IF;
  RAISE NOTICE 'PASS: auto_close_stale_game_sessions force-completes a 5h-stale active session and logs final scores from game_players';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
