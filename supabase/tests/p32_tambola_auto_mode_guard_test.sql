-- P32 test: host_call_tambola_number automatic-mode guard.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P32 migration
-- (20260824020000_p32_host_call_tambola_auto_mode_guard.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p32_tambola_auto_mode_guard_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. An automatic-mode session (next_auto_draw_at already set) rejects a
--      direct host_call_tambola_number call with KITPAT_AUTO_MODE_SERVER_
--      DRIVEN — both with no explicit number and with one.
--   2. A manual-mode session is completely unaffected: host_call_tambola_
--      number still draws a random number and still honours an explicit
--      p_number, exactly as before.
--   3. The server path is untouched: process_due_tambola_auto_draws() (the
--      same function pg_cron calls every 5 seconds) still successfully
--      draws for the due automatic session, and does not touch the manual
--      session at all.

BEGIN;

DO $t$
DECLARE
  u_host uuid := gen_random_uuid();
  g_id   uuid := gen_random_uuid();
  ev_id  uuid;
  s_auto   uuid;
  s_manual uuid;
  chosen integer;
  err    text;
  before_count integer;
  after_count  integer;
  next_draw_before timestamptz;
  next_draw_after  timestamptz;

BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (id, name, phone) VALUES
    (u_host, 'P32 Host', '+910000000960');

  INSERT INTO public.groups (id, name, host_id) VALUES
    (g_id, 'P32 Test Group', u_host);

  INSERT INTO public.events (group_id, theme, party_date, status, created_by)
  VALUES (g_id, 'birthday', now(), 'scheduled', u_host)
  RETURNING id INTO ev_id;

  INSERT INTO public.game_sessions (
    event_id, group_id, game_type, play_mode, status, host_id,
    draw_interval_seconds, next_auto_draw_at
  ) VALUES (
    ev_id, g_id, 'tambola', 'automatic', 'active', u_host,
    8, now() - interval '1 second'
  ) RETURNING id INTO s_auto;

  INSERT INTO public.game_sessions (
    event_id, group_id, game_type, play_mode, status, host_id,
    draw_interval_seconds, next_auto_draw_at
  ) VALUES (
    ev_id, g_id, 'tambola', 'manual', 'active', u_host,
    8, NULL
  ) RETURNING id INTO s_manual;

  ------------------------------------------ 1. automatic mode rejects direct calls
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);

  BEGIN
    chosen := public.host_call_tambola_number(s_auto, NULL);
    RAISE EXCEPTION 'FAIL: direct host_call_tambola_number(auto, NULL) was allowed';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_AUTO_MODE_SERVER_DRIVEN' THEN
      RAISE EXCEPTION 'FAIL: automatic-mode call with no number raised "%", expected KITPAT_AUTO_MODE_SERVER_DRIVEN', err;
    END IF;
  END;

  BEGIN
    chosen := public.host_call_tambola_number(s_auto, 7);
    RAISE EXCEPTION 'FAIL: direct host_call_tambola_number(auto, 7) was allowed';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_AUTO_MODE_SERVER_DRIVEN' THEN
      RAISE EXCEPTION 'FAIL: automatic-mode call with an explicit number raised "%", expected KITPAT_AUTO_MODE_SERVER_DRIVEN', err;
    END IF;
  END;

  IF (SELECT cardinality(called_numbers) FROM public.game_sessions WHERE id = s_auto) <> 0 THEN
    RAISE EXCEPTION 'FAIL: a rejected automatic-mode call still recorded a number';
  END IF;
  RAISE NOTICE 'PASS: a direct host_call_tambola_number call against an automatic-mode session is rejected with KITPAT_AUTO_MODE_SERVER_DRIVEN, with or without an explicit number, and draws nothing';

  ------------------------------------------------- 2. manual mode unaffected
  chosen := public.host_call_tambola_number(s_manual, NULL);
  IF chosen IS NULL OR chosen < 1 OR chosen > 90 THEN
    RAISE EXCEPTION 'FAIL: manual-mode random draw returned %, expected 1-90', chosen;
  END IF;

  -- (chosen % 90) + 1 is always in 1..90 and always distinct from the
  -- random draw above, whatever it happened to land on.
  chosen := public.host_call_tambola_number(s_manual, (chosen % 90) + 1);
  IF chosen NOT BETWEEN 1 AND 90 THEN
    RAISE EXCEPTION 'FAIL: manual-mode explicit call returned %, expected 1-90', chosen;
  END IF;

  SELECT cardinality(called_numbers) INTO after_count FROM public.game_sessions WHERE id = s_manual;
  IF after_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: manual session called_numbers cardinality = %, expected 2', after_count;
  END IF;
  IF (SELECT next_auto_draw_at FROM public.game_sessions WHERE id = s_manual) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: manual session picked up a next_auto_draw_at value';
  END IF;
  RAISE NOTICE 'PASS: a manual-mode session is completely unaffected — random draw and explicit-number draw both still work exactly as before';

  ---------------------------------------------- 3. server auto-draw path untouched
  SELECT cardinality(called_numbers), next_auto_draw_at
    INTO before_count, next_draw_before
  FROM public.game_sessions WHERE id = s_auto;

  PERFORM public.process_due_tambola_auto_draws();

  SELECT cardinality(called_numbers), next_auto_draw_at
    INTO after_count, next_draw_after
  FROM public.game_sessions WHERE id = s_auto;

  IF after_count <= before_count THEN
    RAISE EXCEPTION 'FAIL: process_due_tambola_auto_draws did not draw for the due automatic session (before=%, after=%)', before_count, after_count;
  END IF;
  IF next_draw_after IS NULL OR next_draw_after <= now() THEN
    RAISE EXCEPTION 'FAIL: automatic session next_auto_draw_at after the sweep = %, expected a future timestamp', next_draw_after;
  END IF;

  -- The manual session must not have been touched by the sweep at all.
  IF (SELECT cardinality(called_numbers) FROM public.game_sessions WHERE id = s_manual) <> 2 THEN
    RAISE EXCEPTION 'FAIL: process_due_tambola_auto_draws touched the manual-mode session';
  END IF;
  RAISE NOTICE 'PASS: process_due_tambola_auto_draws() still draws for the due automatic session and rearms next_auto_draw_at, and never touches the manual session — the server path is unaffected by the new guard';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
