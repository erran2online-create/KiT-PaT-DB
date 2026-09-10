-- AP11 test: tambola_variants.default_tickets_per_player, and the three
-- admin game-session read RPCs.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0-AP10 and this migration
-- (20260909030000_ap11_admin_games_sessions_read.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap11_admin_games_sessions_read_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. tambola_variants.default_tickets_per_player exists, defaults to 1,
--      and its CHECK rejects 0 and 7.
--   b. Each of the three RPCs raises KITPAT_ADMIN_ONLY for a non-admin.
--   c. Each returns correct rows for an active admin against a seeded
--      fixture session with a player, a round, a prize and its winner,
--      a tambola ticket, an action, and a claim.
--   d. anon holds no EXECUTE on any of the three.
--   e. A plain group member's own view of game_sessions (existing RLS)
--      is unchanged: sees their own group's session, not an unrelated
--      one.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap11.owner.test@kitpat.in';
  non_admin_email text := 'ap11.notadmin.test@kitpat.in';
  host_user_id uuid;
  member_user_id uuid;
  outsider_user_id uuid;
  group_id uuid;
  other_group_id uuid;
  session_id uuid;
  other_session_id uuid;
  round_id uuid;
  prize_id uuid;
  err text;
  default_val integer;
  session_row record;
  detail jsonb;
  players_json jsonb;
  prizes_json jsonb;
  answers_count integer;
  claim_found boolean;
  action_found boolean;
  anon_has_execute boolean;
  visible_count integer;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES (owner_email, 'owner', true)
  ON CONFLICT (email) DO UPDATE SET role = 'owner', is_active = true;

  INSERT INTO public.users (name, phone, city) VALUES ('AP11 Host', '9977000001', 'Pune') RETURNING id INTO host_user_id;
  INSERT INTO public.users (name, phone, city) VALUES ('AP11 Member', '9977000002', 'Pune') RETURNING id INTO member_user_id;
  INSERT INTO public.users (name, phone, city) VALUES ('AP11 Outsider', '9977000003', 'Pune') RETURNING id INTO outsider_user_id;

  INSERT INTO public.groups (name, host_id, city) VALUES ('AP11 Test Group ' || substr(gen_random_uuid()::text, 1, 8), host_user_id, 'Pune') RETURNING id INTO group_id;
  INSERT INTO public.groups (name, host_id, city) VALUES ('AP11 Other Group ' || substr(gen_random_uuid()::text, 1, 8), outsider_user_id, 'Pune') RETURNING id INTO other_group_id;

  INSERT INTO public.members (group_id, user_id, role) VALUES
    (group_id, host_user_id, 'host'),
    (group_id, member_user_id, 'member');
  INSERT INTO public.members (group_id, user_id, role) VALUES (other_group_id, outsider_user_id, 'host');

  INSERT INTO public.game_sessions (event_id, group_id, game_type, variant, play_mode, status, host_id, started_at, ended_at)
  VALUES (NULL, group_id, 'tambola', 'classic', 'manual', 'completed', host_user_id, now() - interval '1 hour', now())
  RETURNING id INTO session_id;

  INSERT INTO public.game_sessions (event_id, group_id, game_type, variant, play_mode, status, host_id)
  VALUES (NULL, other_group_id, 'tambola', 'classic', 'manual', 'lobby', outsider_user_id)
  RETURNING id INTO other_session_id;

  INSERT INTO public.game_players (session_id, user_id, status, score) VALUES (session_id, member_user_id, 'joined', 10);

  INSERT INTO public.game_rounds (session_id, round_no, status, completed_at)
  VALUES (session_id, 1, 'completed', now())
  RETURNING id INTO round_id;

  INSERT INTO public.game_prizes (session_id, prize_type, display_name, total_slots, awarded_slots, is_closed)
  VALUES (session_id, 'early_five', 'Early Five', 1, 1, true)
  RETURNING id INTO prize_id;

  INSERT INTO public.tambola_tickets (session_id, user_id, ticket_no, grid)
  VALUES (session_id, member_user_id, 1, '[[1,2,3,4,5,6,7,8,9]]'::jsonb);

  INSERT INTO public.game_actions (session_id, round_id, user_id, action_type, payload, server_score)
  VALUES (session_id, round_id, member_user_id, 'mark_number', '{"number": 42}'::jsonb, 5);

  INSERT INTO public.game_claims (session_id, prize_id, user_id, status, claimed_at, verified_at)
  VALUES (session_id, prize_id, member_user_id, 'verified', now(), now());

  ---------------------------------------------------- a. default_tickets_per_player
  SELECT default_tickets_per_player INTO default_val FROM public.tambola_variants LIMIT 1;
  IF default_val <> 1 THEN
    RAISE EXCEPTION 'FAIL: tambola_variants.default_tickets_per_player = %, expected 1', default_val;
  END IF;

  BEGIN
    UPDATE public.tambola_variants SET default_tickets_per_player = 0 WHERE key = (SELECT key FROM public.tambola_variants LIMIT 1);
    RAISE EXCEPTION 'FAIL: default_tickets_per_player accepted 0';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    UPDATE public.tambola_variants SET default_tickets_per_player = 7 WHERE key = (SELECT key FROM public.tambola_variants LIMIT 1);
    RAISE EXCEPTION 'FAIL: default_tickets_per_player accepted 7';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  RAISE NOTICE 'PASS: default_tickets_per_player exists, defaults to 1, and the CHECK rejects 0 and 7';

  --------------------------------------------------- b. KITPAT_ADMIN_ONLY gate
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', non_admin_email, 'role', 'authenticated')::text, true);

  BEGIN
    PERFORM * FROM public.admin_list_game_sessions();
    RAISE EXCEPTION 'FAIL: admin_list_game_sessions succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_list_game_sessions raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;

  BEGIN
    PERFORM public.admin_game_session_detail(session_id);
    RAISE EXCEPTION 'FAIL: admin_game_session_detail succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_game_session_detail raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;

  BEGIN
    PERFORM * FROM public.admin_list_game_answers(session_id);
    RAISE EXCEPTION 'FAIL: admin_list_game_answers succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_list_game_answers raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: all three RPCs raise KITPAT_ADMIN_ONLY for a non-admin';

  --------------------------------------------------- c. active admin: correct rows
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);

  SELECT * INTO session_row FROM public.admin_list_game_sessions(NULL, 'tambola', NULL, 100, 0) WHERE id = session_id;
  IF session_row.id IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_list_game_sessions did not return the fixture session';
  END IF;
  IF session_row.player_count <> 1 OR session_row.ticket_count <> 1 OR session_row.prize_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: admin_list_game_sessions counts = (players=%, tickets=%, prizes=%), expected (1,1,1)', session_row.player_count, session_row.ticket_count, session_row.prize_count;
  END IF;
  IF session_row.group_name IS NULL OR session_row.host_name <> 'AP11 Host' THEN
    RAISE EXCEPTION 'FAIL: admin_list_game_sessions group_name/host_name = %/%, expected the fixture group and AP11 Host', session_row.group_name, session_row.host_name;
  END IF;

  detail := public.admin_game_session_detail(session_id);
  players_json := detail -> 'players';
  prizes_json := detail -> 'prizes';
  IF jsonb_array_length(players_json) <> 1 OR (players_json -> 0 ->> 'user_name') <> 'AP11 Member' THEN
    RAISE EXCEPTION 'FAIL: admin_game_session_detail players = %, expected one row for AP11 Member', players_json;
  END IF;
  IF jsonb_array_length(prizes_json) <> 1
     OR jsonb_array_length(prizes_json -> 0 -> 'winners') <> 1
     OR (prizes_json -> 0 -> 'winners' -> 0 ->> 'user_name') <> 'AP11 Member' THEN
    RAISE EXCEPTION 'FAIL: admin_game_session_detail prizes/winners = %, expected one prize with AP11 Member as the verified winner', prizes_json;
  END IF;
  IF jsonb_array_length(detail -> 'rounds') <> 1 THEN
    RAISE EXCEPTION 'FAIL: admin_game_session_detail rounds = %, expected 1', detail -> 'rounds';
  END IF;
  IF jsonb_array_length(detail -> 'tambola_tickets') <> 1 THEN
    RAISE EXCEPTION 'FAIL: admin_game_session_detail tambola_tickets = %, expected 1', detail -> 'tambola_tickets';
  END IF;

  SELECT count(*) INTO answers_count FROM public.admin_list_game_answers(session_id, 100, 0);
  IF answers_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: admin_list_game_answers returned % rows, expected 2 (one action, one claim)', answers_count;
  END IF;

  SELECT bool_or(kind = 'action' AND label = 'mark_number' AND outcome = '5') INTO action_found FROM public.admin_list_game_answers(session_id, 100, 0);
  SELECT bool_or(kind = 'claim' AND label = 'Early Five' AND outcome = 'verified') INTO claim_found FROM public.admin_list_game_answers(session_id, 100, 0);
  IF NOT coalesce(action_found, false) THEN
    RAISE EXCEPTION 'FAIL: admin_list_game_answers did not include the fixture action row correctly';
  END IF;
  IF NOT coalesce(claim_found, false) THEN
    RAISE EXCEPTION 'FAIL: admin_list_game_answers did not include the fixture claim row correctly';
  END IF;
  RAISE NOTICE 'PASS: all three RPCs return correct rows for an active admin against the fixture session';

  ------------------------------------------------------------------ d. anon lockout
  SELECT has_function_privilege('anon', 'public.admin_list_game_sessions(text,text,text,int,int)', 'EXECUTE') INTO anon_has_execute;
  IF anon_has_execute IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_list_game_sessions(...)';
  END IF;
  SELECT has_function_privilege('anon', 'public.admin_game_session_detail(uuid)', 'EXECUTE') INTO anon_has_execute;
  IF anon_has_execute IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_game_session_detail(uuid)';
  END IF;
  SELECT has_function_privilege('anon', 'public.admin_list_game_answers(uuid,int,int)', 'EXECUTE') INTO anon_has_execute;
  IF anon_has_execute IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_list_game_answers(uuid,int,int)';
  END IF;
  RAISE NOTICE 'PASS: anon holds no EXECUTE on any of the three RPCs';

  --------------------------------------------------- e. member RLS unchanged
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_user_id::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO visible_count FROM public.game_sessions WHERE id = session_id;
  RESET ROLE;
  IF visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: a member of the session''s group could not see it via ordinary RLS (count=%)', visible_count;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_user_id::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO visible_count FROM public.game_sessions WHERE id = other_session_id;
  RESET ROLE;
  IF visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: a member could see an unrelated group''s session directly (count=%), expected 0 -- RLS should be unchanged', visible_count;
  END IF;
  RAISE NOTICE 'PASS: a plain group member''s own view of game_sessions (existing RLS) is unchanged';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
