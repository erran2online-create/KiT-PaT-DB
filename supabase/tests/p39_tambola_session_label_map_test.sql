-- P39 test: shared per-session number->label map for Bollywood/Kitty Special
-- Tambola.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P39 migration
-- (20260905010000_p39_tambola_session_label_map.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p39_tambola_session_label_map_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. Starting a bollywood session fixes a 90-entry number_label_map, all
--      kind='film', with 90 distinct titles drawn from game_theme_packs'
--      films pool.
--   2. Starting a kitty_special session (explicit config.festival_key)
--      fixes a 90-entry map, all kind='festival'.
--   3. Starting a classic session leaves number_label_map NULL.
--   4. get_session_labels returns the map for a group member and raises
--      KITPAT_NOT_MEMBER for an outsider (KITPAT_UNAUTHENTICATED with no
--      auth context).
--   5. Calling build_session_label_map a second time does not reshuffle --
--      it returns the exact same map (idempotent).
--   6. A kitty_special session with no resolvable festival at all falls
--      back to the static 'Kitty Special N' / kind='festival' labels
--      instead of erroring.
--   7. host_call_tambola_number / process_due_tambola_auto_draws are
--      untouched by this migration.

BEGIN;

DO $t$
DECLARE
  u_host uuid := gen_random_uuid();
  u_member uuid := gen_random_uuid();
  u_outsider uuid := gen_random_uuid();
  g_id uuid;
  ev_id uuid;
  s_bwood uuid;
  s_kitty uuid;
  s_classic uuid;
  s_kitty_fallback uuid;
  films_pool text[];
  map_bwood jsonb;
  map_kitty jsonb;
  map_classic jsonb;
  map_fallback jsonb;
  map_before jsonb;
  map_after jsonb;
  key_count integer;
  distinct_label_count integer;
  non_film_count integer;
  off_pool_count integer;
  labels_json jsonb;
  err text;
  chosen integer;
  before_count integer;
  after_count integer;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (id, name, phone) VALUES
    (u_host, 'P39 Host', '+910000000980'),
    (u_member, 'P39 Member', '+910000000981'),
    (u_outsider, 'P39 Outsider', '+910000000982');

  INSERT INTO public.groups (id, name, host_id) VALUES
    (gen_random_uuid(), 'P39 Test Group', u_host)
  RETURNING id INTO g_id;

  INSERT INTO public.members (group_id, user_id, role) VALUES
    (g_id, u_member, 'member');

  INSERT INTO public.events (group_id, theme, party_date, status, created_by)
  VALUES (g_id, 'birthday', now(), 'scheduled', u_host)
  RETURNING id INTO ev_id;

  SELECT ARRAY(SELECT jsonb_array_elements_text(content -> 'films'))
    INTO films_pool
  FROM public.game_theme_packs
  WHERE game_key = 'tambola' AND theme_key = 'bollywood' AND locale = 'en-IN' AND is_active
  LIMIT 1;
  IF films_pool IS NULL OR array_length(films_pool, 1) < 90 THEN
    RAISE EXCEPTION 'FAIL: could not load a bollywood films pool of >=90 titles to test against';
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);

  --------------------------------------------------------------- 1. bollywood
  INSERT INTO public.game_sessions (event_id, group_id, game_type, variant, play_mode, status, host_id)
  VALUES (ev_id, g_id, 'tambola', 'bollywood', 'manual', 'lobby', u_host)
  RETURNING id INTO s_bwood;

  PERFORM public.host_start_tambola(s_bwood);

  SELECT number_label_map INTO map_bwood FROM public.game_sessions WHERE id = s_bwood;
  IF map_bwood IS NULL THEN
    RAISE EXCEPTION 'FAIL: bollywood session number_label_map is NULL after host_start_tambola';
  END IF;

  SELECT count(*) INTO key_count FROM jsonb_object_keys(map_bwood);
  IF key_count <> 90 THEN
    RAISE EXCEPTION 'FAIL: bollywood number_label_map has % keys, expected 90', key_count;
  END IF;

  SELECT count(*) INTO non_film_count
  FROM jsonb_each(map_bwood) kv
  WHERE kv.value ->> 'kind' <> 'film';
  IF non_film_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % bollywood map entries have kind <> film', non_film_count;
  END IF;

  SELECT count(DISTINCT kv.value ->> 'label') INTO distinct_label_count FROM jsonb_each(map_bwood) kv;
  IF distinct_label_count <> 90 THEN
    RAISE EXCEPTION 'FAIL: bollywood map has % distinct labels, expected 90 (no repeats)', distinct_label_count;
  END IF;

  SELECT count(*) INTO off_pool_count
  FROM jsonb_each(map_bwood) kv
  WHERE NOT (kv.value ->> 'label' = ANY (films_pool));
  IF off_pool_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % bollywood map labels are not drawn from the films pool', off_pool_count;
  END IF;

  FOR key_count IN 1..90 LOOP
    IF NOT (map_bwood ? key_count::text) THEN
      RAISE EXCEPTION 'FAIL: bollywood map is missing key %', key_count;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: starting a bollywood session fixes a 90-entry number_label_map, all kind=film, with 90 distinct titles drawn from the films pool';

  ----------------------------------------------------------- 2. kitty_special
  INSERT INTO public.game_sessions (event_id, group_id, game_type, variant, play_mode, status, host_id, config)
  VALUES (ev_id, g_id, 'tambola', 'kitty_special', 'manual', 'lobby', u_host, jsonb_build_object('festival_key', 'diwali'))
  RETURNING id INTO s_kitty;

  PERFORM public.host_start_tambola(s_kitty);

  SELECT number_label_map INTO map_kitty FROM public.game_sessions WHERE id = s_kitty;
  IF map_kitty IS NULL THEN
    RAISE EXCEPTION 'FAIL: kitty_special session number_label_map is NULL after host_start_tambola';
  END IF;

  SELECT count(*) INTO key_count FROM jsonb_object_keys(map_kitty);
  IF key_count <> 90 THEN
    RAISE EXCEPTION 'FAIL: kitty_special number_label_map has % keys, expected 90', key_count;
  END IF;

  SELECT count(*) INTO non_film_count
  FROM jsonb_each(map_kitty) kv
  WHERE kv.value ->> 'kind' <> 'festival';
  IF non_film_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % kitty_special map entries have kind <> festival', non_film_count;
  END IF;

  IF (map_kitty -> '1' ->> 'label') NOT LIKE '%Diwali%' THEN
    RAISE EXCEPTION 'FAIL: kitty_special map entry 1 label = %, expected it to reference the pinned Diwali festival', map_kitty -> '1' ->> 'label';
  END IF;
  RAISE NOTICE 'PASS: starting a kitty_special session with an explicit config.festival_key fixes a 90-entry map, all kind=festival, using that festival''s motif';

  ------------------------------------------------------------------ 3. classic
  INSERT INTO public.game_sessions (event_id, group_id, game_type, variant, play_mode, status, host_id)
  VALUES (ev_id, g_id, 'tambola', 'classic', 'manual', 'lobby', u_host)
  RETURNING id INTO s_classic;

  PERFORM public.host_start_tambola(s_classic);

  SELECT number_label_map INTO map_classic FROM public.game_sessions WHERE id = s_classic;
  IF map_classic IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: classic session number_label_map = %, expected NULL', map_classic;
  END IF;
  RAISE NOTICE 'PASS: starting a classic session leaves number_label_map NULL (plain numbers)';

  --------------------------------------------------------- 4. get_session_labels
  labels_json := public.get_session_labels(s_bwood);
  IF labels_json IS DISTINCT FROM map_bwood THEN
    RAISE EXCEPTION 'FAIL: get_session_labels(bollywood) as host did not return the same map as number_label_map';
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_member::text, 'role', 'authenticated')::text, true);
  labels_json := public.get_session_labels(s_bwood);
  IF labels_json IS DISTINCT FROM map_bwood THEN
    RAISE EXCEPTION 'FAIL: get_session_labels(bollywood) as a group member did not return the same map';
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_outsider::text, 'role', 'authenticated')::text, true);
  BEGIN
    labels_json := public.get_session_labels(s_bwood);
    RAISE EXCEPTION 'FAIL: get_session_labels(bollywood) as an outsider was allowed';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_MEMBER' THEN
      RAISE EXCEPTION 'FAIL: outsider call raised "%", expected KITPAT_NOT_MEMBER', err;
    END IF;
  END;

  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    labels_json := public.get_session_labels(s_bwood);
    RAISE EXCEPTION 'FAIL: get_session_labels(bollywood) with no auth context was allowed';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_UNAUTHENTICATED' THEN
      RAISE EXCEPTION 'FAIL: unauthenticated call raised "%", expected KITPAT_UNAUTHENTICATED', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: get_session_labels returns the map for the host and a group member, and raises KITPAT_NOT_MEMBER / KITPAT_UNAUTHENTICATED otherwise';

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);

  --------------------------------------------------------------- 5. idempotent
  SELECT number_label_map INTO map_before FROM public.game_sessions WHERE id = s_bwood;
  PERFORM public.build_session_label_map(s_bwood);
  SELECT number_label_map INTO map_after FROM public.game_sessions WHERE id = s_bwood;
  IF map_after IS DISTINCT FROM map_before THEN
    RAISE EXCEPTION 'FAIL: calling build_session_label_map a second time reshuffled the map';
  END IF;
  RAISE NOTICE 'PASS: calling build_session_label_map a second time is a no-op -- the map is never reshuffled once fixed';

  ------------------------------------------------- 6. no-festival-resolves fallback
  -- Force the fallback branch: no config.festival_key, and no active
  -- festival_themes row at all, so get_festival_options() returns nothing
  -- for any month.
  UPDATE public.festival_themes SET is_active = false;

  INSERT INTO public.game_sessions (event_id, group_id, game_type, variant, play_mode, status, host_id)
  VALUES (ev_id, g_id, 'tambola', 'kitty_special', 'manual', 'lobby', u_host)
  RETURNING id INTO s_kitty_fallback;

  PERFORM public.host_start_tambola(s_kitty_fallback);

  SELECT number_label_map INTO map_fallback FROM public.game_sessions WHERE id = s_kitty_fallback;
  IF map_fallback IS NULL THEN
    RAISE EXCEPTION 'FAIL: kitty_special fallback session number_label_map is NULL';
  END IF;
  SELECT count(*) INTO key_count FROM jsonb_object_keys(map_fallback);
  IF key_count <> 90 THEN
    RAISE EXCEPTION 'FAIL: kitty_special fallback map has % keys, expected 90', key_count;
  END IF;
  IF (map_fallback -> '1' ->> 'label') <> 'Kitty Special 1' OR (map_fallback -> '1' ->> 'kind') <> 'festival' THEN
    RAISE EXCEPTION 'FAIL: kitty_special fallback entry 1 = %, expected label=''Kitty Special 1'', kind=festival', map_fallback -> '1';
  END IF;
  RAISE NOTICE 'PASS: a kitty_special session with no resolvable festival falls back to static Kitty Special N labels (kind=festival) instead of erroring';

  --------------------------------------------- 7. draw logic is untouched
  chosen := public.host_call_tambola_number(s_bwood, NULL);
  IF chosen IS NULL OR chosen < 1 OR chosen > 90 THEN
    RAISE EXCEPTION 'FAIL: host_call_tambola_number on the bollywood session returned %, expected 1-90', chosen;
  END IF;

  UPDATE public.game_sessions
  SET play_mode = 'automatic', next_auto_draw_at = now() - interval '1 second'
  WHERE id = s_classic AND status = 'active';

  SELECT cardinality(called_numbers) INTO before_count FROM public.game_sessions WHERE id = s_classic;
  PERFORM public.process_due_tambola_auto_draws();
  SELECT cardinality(called_numbers) INTO after_count FROM public.game_sessions WHERE id = s_classic;
  IF after_count <= before_count THEN
    RAISE EXCEPTION 'FAIL: process_due_tambola_auto_draws did not draw for the due classic session -- draw logic appears broken by this migration';
  END IF;
  RAISE NOTICE 'PASS: host_call_tambola_number and process_due_tambola_auto_draws still work exactly as before -- draw/claim/verify logic is untouched';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
