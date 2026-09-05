-- P40 test: public.game_events grant lockdown + read policy.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P40 migration
-- (20260906010000_p40_game_events_grant_lockdown.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p40_game_events_grant_lockdown_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. anon holds none of SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/
--      TRIGGER on public.game_events.
--   2. authenticated holds SELECT only (none of the write/DDL privileges).
--   3. A group member can SELECT their session's events.
--   4. An outsider gets zero rows for that same session (RLS filters
--      silently -- no error).
--   5. A direct authenticated INSERT / DELETE / TRUNCATE on game_events
--      each fail with insufficient_privilege (42501).
--   6. An owner-context insert (simulating a SECURITY DEFINER engine RPC,
--      which runs as the table owner and bypasses RLS) still succeeds.
--   7. Selecting through the public.session_events view still resolves and
--      returns the same rows for an authenticated member.
--
-- Caveat worth recording (not asserted as a failure here, since it was not
-- part of the requested fix): public.session_events is a plain view owned
-- by the table owner, not a security_invoker view. Per Postgres's view
-- privilege model, a plain view's underlying query is permission-checked
-- as the VIEW OWNER, not the querying user -- so if the view's owner is
-- also game_events' owner (it is: postgres, per the original schema dump),
-- the view's read of game_events runs as the table owner, who bypasses RLS
-- by default. In practice this means any role holding SELECT on the view
-- (currently authenticated, service_role) can read every group's rows
-- through session_events, even though direct queries against game_events
-- are correctly scoped by the policy above. Closing that specific gap
-- would need `ALTER VIEW public.session_events SET (security_invoker =
-- true);` (Postgres 15+) or dropping the view, neither of which this task
-- authorized ("leave the view as-is"). This test only asserts the view
-- still resolves for a member, per what was actually requested; it does
-- NOT assert an outsider gets zero rows through the view, because that
-- would currently fail.

BEGIN;

DO $t$
DECLARE
  u_host uuid := gen_random_uuid();
  u_member uuid := gen_random_uuid();
  u_outsider uuid := gen_random_uuid();
  g_id uuid;
  ev_id uuid;
  s_id uuid;
  ev_row_id bigint;
  member_visible_count integer;
  outsider_visible_count integer;
  view_visible_count integer;
  write_blocked boolean;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (id, name, phone) VALUES
    (u_host, 'P40 Host', '+910000000990'),
    (u_member, 'P40 Member', '+910000000991'),
    (u_outsider, 'P40 Outsider', '+910000000992');

  INSERT INTO public.groups (id, name, host_id) VALUES
    (gen_random_uuid(), 'P40 Test Group', u_host)
  RETURNING id INTO g_id;

  INSERT INTO public.members (group_id, user_id, role) VALUES
    (g_id, u_member, 'member');

  INSERT INTO public.events (group_id, theme, party_date, status, created_by)
  VALUES (g_id, 'birthday', now(), 'scheduled', u_host)
  RETURNING id INTO ev_id;

  INSERT INTO public.game_sessions (event_id, group_id, game_type, variant, play_mode, status, host_id)
  VALUES (ev_id, g_id, 'tambola', 'classic', 'manual', 'active', u_host)
  RETURNING id INTO s_id;

  --------------------------------------------- 6. owner-context insert (engine-style)
  -- The ambient role running this test script owns public.game_events
  -- (same as every SECURITY DEFINER game RPC), so this direct insert
  -- exercises exactly the path host_start_tambola / host_call_tambola_number
  -- / etc. rely on.
  INSERT INTO public.game_events (session_id, event_type, actor_id, payload)
  VALUES (s_id, 'session_started', u_host, jsonb_build_object('mode', 'manual'))
  RETURNING id INTO ev_row_id;

  IF ev_row_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: owner-context insert into game_events did not return a row id';
  END IF;
  RAISE NOTICE 'PASS: an owner-context insert into game_events (simulating a SECURITY DEFINER engine RPC) still succeeds';

  --------------------------------------------------------- 1 & 2. grant checks
  IF has_table_privilege('anon', 'public.game_events', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
    RAISE EXCEPTION 'FAIL: anon still holds at least one privilege on public.game_events';
  END IF;
  RAISE NOTICE 'PASS: anon holds no privileges at all on public.game_events';

  IF NOT has_table_privilege('authenticated', 'public.game_events', 'SELECT') THEN
    RAISE EXCEPTION 'FAIL: authenticated has lost SELECT on public.game_events';
  END IF;
  IF has_table_privilege('authenticated', 'public.game_events', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
    RAISE EXCEPTION 'FAIL: authenticated still holds at least one write/DDL privilege on public.game_events';
  END IF;
  RAISE NOTICE 'PASS: authenticated holds SELECT only on public.game_events (no INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER)';

  ------------------------------------------------------------- 3. member reads
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_member::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;

  SELECT count(*) INTO member_visible_count FROM public.game_events WHERE session_id = s_id;
  IF member_visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: group member sees % game_events rows for their session, expected 1', member_visible_count;
  END IF;

  ------------------------------------------------------- 7. session_events view
  SELECT count(*) INTO view_visible_count FROM public.session_events WHERE session_id = s_id;
  IF view_visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: group member sees % session_events (view) rows for their session, expected 1 -- the view no longer resolves after the grant change', view_visible_count;
  END IF;
  RAISE NOTICE 'PASS: a group member reads their session''s events directly via game_events (1 row) and the count matches through the public.session_events view';

  RESET ROLE;

  ------------------------------------------------------------- 4. outsider reads
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_outsider::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;

  SELECT count(*) INTO outsider_visible_count FROM public.game_events WHERE session_id = s_id;
  IF outsider_visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: an outsider sees % game_events rows for a session in a group they do not belong to, expected 0', outsider_visible_count;
  END IF;
  RAISE NOTICE 'PASS: an outsider gets zero game_events rows for a session in a group they are not a member/host of (RLS filters silently, no error)';

  RESET ROLE;

  --------------------------------------------------- 5. direct writes are blocked
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_member::text, 'role', 'authenticated')::text, true);

  SET LOCAL ROLE authenticated;
  BEGIN
    INSERT INTO public.game_events (session_id, event_type, actor_id, payload)
    VALUES (s_id, 'forged_event', u_member, '{}'::jsonb);
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: direct INSERT into game_events as authenticated was not rejected with insufficient_privilege';
  END IF;

  SET LOCAL ROLE authenticated;
  BEGIN
    DELETE FROM public.game_events WHERE id = ev_row_id;
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: direct DELETE on game_events as authenticated was not rejected with insufficient_privilege';
  END IF;

  SET LOCAL ROLE authenticated;
  BEGIN
    TRUNCATE public.game_events;
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: TRUNCATE on game_events as authenticated was not rejected with insufficient_privilege';
  END IF;

  -- The original fixture row must have survived every blocked attempt.
  IF NOT EXISTS (SELECT 1 FROM public.game_events WHERE id = ev_row_id) THEN
    RAISE EXCEPTION 'FAIL: the fixture game_events row did not survive the blocked-write attempts';
  END IF;
  RAISE NOTICE 'PASS: direct INSERT, DELETE, and TRUNCATE on game_events as authenticated all fail with insufficient_privilege, and no data was lost';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
