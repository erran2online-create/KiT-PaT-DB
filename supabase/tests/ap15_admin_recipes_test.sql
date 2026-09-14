-- AP15 test: admin_list_recipes/admin_recipe_detail/admin_upsert_recipe/
-- admin_set_recipe_active's role gates, the ai->seeded source flip on
-- edit, that deactivation never touches saved_recipes, that both writes
-- audit, and that anon has no EXECUTE on any of the four.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has this migration
-- (20260915010000_ap15_admin_recipes.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap15_admin_recipes_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap15-owner@kitpat.in';
  member_admin_email text := 'ap15-memberadmin@kitpat.in';
  outsider_id uuid;
  ai_recipe_id uuid;
  member_user_id uuid;
  err text;
  audit_count_before integer;
  audit_count_after integer;
  row_out public.recipes;
  saved_count integer;
  list_count integer;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES (owner_email, 'owner', true)
    ON CONFLICT (email) DO UPDATE SET role = 'owner', is_active = true;
  INSERT INTO public.admins (email, role, is_active) VALUES (member_admin_email, 'member', true)
    ON CONFLICT (email) DO UPDATE SET role = 'member', is_active = true;
  INSERT INTO public.users (name, phone, city) VALUES ('AP15 Outsider', '9922200001', 'Pune') RETURNING id INTO outsider_id;
  INSERT INTO public.users (name, phone, city) VALUES ('AP15 Member', '9922200002', 'Pune') RETURNING id INTO member_user_id;

  INSERT INTO public.recipes (normalized_key, title, ingredients, steps, source, ai_provider, ai_model)
  VALUES (public.normalize_food_key('AP15 AI Test Dish'), 'AP15 AI Test Dish', '[]'::jsonb, '[]'::jsonb, 'ai', 'anthropic', 'claude-haiku-4-5-20251001')
  RETURNING id INTO ai_recipe_id;

  -- The member saves the AI recipe before it's ever touched by an admin.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_user_id::text, 'role', 'authenticated')::text, true);
  PERFORM public.save_recipe(ai_recipe_id);

  ------------------------------------------------- a. KITPAT_ADMIN_ONLY for a non-admin
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', outsider_id::text, 'email', 'ap15-not-an-admin@example.com', 'role', 'authenticated')::text, true);

  BEGIN
    PERFORM public.admin_list_recipes();
    RAISE EXCEPTION 'FAIL: a non-admin was able to call admin_list_recipes';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN RAISE EXCEPTION 'FAIL: non-admin admin_list_recipes raised "%", expected KITPAT_ADMIN_ONLY', err; END IF;
  END;

  BEGIN
    PERFORM public.admin_recipe_detail(ai_recipe_id);
    RAISE EXCEPTION 'FAIL: a non-admin was able to call admin_recipe_detail';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN RAISE EXCEPTION 'FAIL: non-admin admin_recipe_detail raised "%", expected KITPAT_ADMIN_ONLY', err; END IF;
  END;

  BEGIN
    PERFORM public.admin_upsert_recipe('AP15 Should Not Insert');
    RAISE EXCEPTION 'FAIL: a non-admin was able to call admin_upsert_recipe';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN RAISE EXCEPTION 'FAIL: non-admin admin_upsert_recipe raised "%", expected KITPAT_ADMIN_ONLY', err; END IF;
  END;

  BEGIN
    PERFORM public.admin_set_recipe_active(ai_recipe_id, false);
    RAISE EXCEPTION 'FAIL: a non-admin was able to call admin_set_recipe_active';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN RAISE EXCEPTION 'FAIL: non-admin admin_set_recipe_active raised "%", expected KITPAT_ADMIN_ONLY', err; END IF;
  END;
  RAISE NOTICE 'PASS: all four RPCs raise KITPAT_ADMIN_ONLY for a non-admin';

  ------------------------------------------------- b. KITPAT_INSUFFICIENT_ROLE for a member admin
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', member_admin_email, 'role', 'authenticated')::text, true);

  BEGIN
    PERFORM public.admin_upsert_recipe('AP15 Should Not Insert Either');
    RAISE EXCEPTION 'FAIL: a member-role admin was able to call admin_upsert_recipe';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN RAISE EXCEPTION 'FAIL: member-admin admin_upsert_recipe raised "%", expected KITPAT_INSUFFICIENT_ROLE', err; END IF;
  END;

  BEGIN
    PERFORM public.admin_set_recipe_active(ai_recipe_id, false);
    RAISE EXCEPTION 'FAIL: a member-role admin was able to call admin_set_recipe_active';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN RAISE EXCEPTION 'FAIL: member-admin admin_set_recipe_active raised "%", expected KITPAT_INSUFFICIENT_ROLE', err; END IF;
  END;
  RAISE NOTICE 'PASS: admin_upsert_recipe and admin_set_recipe_active raise KITPAT_INSUFFICIENT_ROLE for an active admin whose role is member';

  ------------------------------------------------- c. owner: list/detail succeed
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO list_count FROM public.admin_list_recipes(p_source := 'ai');
  IF list_count < 1 THEN
    RAISE EXCEPTION 'FAIL: admin_list_recipes(p_source:=''ai'') did not return the AP15 AI test recipe';
  END IF;
  PERFORM public.admin_recipe_detail(ai_recipe_id);
  RAISE NOTICE 'PASS: an owner can call admin_list_recipes (source filter works) and admin_recipe_detail';

  ------------------------------------------------- d. editing an ai recipe flips source to seeded, and audits
  SELECT count(*) INTO audit_count_before FROM public.admin_audit;

  row_out := public.admin_upsert_recipe(
    p_title := 'AP15 AI Test Dish (corrected)',
    p_recipe_id := ai_recipe_id,
    p_ingredients := '[{"item":"test ingredient","quantity":"1"}]'::jsonb,
    p_steps := '["Do the test step."]'::jsonb
  );
  IF row_out.source <> 'seeded' THEN
    RAISE EXCEPTION 'FAIL: editing an ai-sourced recipe did not flip source to seeded (source=%)', row_out.source;
  END IF;
  IF row_out.title <> 'AP15 AI Test Dish (corrected)' THEN
    RAISE EXCEPTION 'FAIL: admin_upsert_recipe did not update the title: %', row_out.title;
  END IF;

  SELECT count(*) INTO audit_count_after FROM public.admin_audit;
  IF audit_count_after <> audit_count_before + 1 THEN
    RAISE EXCEPTION 'FAIL: admin_upsert_recipe (edit) did not write exactly one admin_audit row (before=%, after=%)', audit_count_before, audit_count_after;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_audit
    WHERE action = 'update:recipe' AND target_type = 'recipes' AND target_id = ai_recipe_id::text AND actor_email = owner_email
    ORDER BY created_at DESC LIMIT 1
  ) THEN
    RAISE EXCEPTION 'FAIL: the admin_audit row for the edit does not have the expected action/target_type/target_id/actor_email';
  END IF;
  RAISE NOTICE 'PASS: an owner editing an ai-sourced recipe flips its source to seeded and writes exactly one admin_audit row';

  ------------------------------------------------- e. deactivation writes an audit row and never touches saved_recipes
  SELECT count(*) INTO audit_count_before FROM public.admin_audit;
  row_out := public.admin_set_recipe_active(ai_recipe_id, false);
  IF row_out.is_active <> false THEN
    RAISE EXCEPTION 'FAIL: admin_set_recipe_active did not persist is_active=false';
  END IF;
  SELECT count(*) INTO audit_count_after FROM public.admin_audit;
  IF audit_count_after <> audit_count_before + 1 THEN
    RAISE EXCEPTION 'FAIL: admin_set_recipe_active did not write exactly one admin_audit row (before=%, after=%)', audit_count_before, audit_count_after;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_audit
    WHERE action = 'set_active:recipe' AND target_type = 'recipes' AND target_id = ai_recipe_id::text AND actor_email = owner_email
    ORDER BY created_at DESC LIMIT 1
  ) THEN
    RAISE EXCEPTION 'FAIL: the admin_audit row for the deactivation does not have the expected action/target_type/target_id/actor_email';
  END IF;

  SELECT count(*) INTO saved_count FROM public.saved_recipes WHERE user_id = member_user_id AND recipe_id = ai_recipe_id;
  IF saved_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: deactivating the recipe removed it from the member''s saved_recipes (saved_count=%)', saved_count;
  END IF;
  RAISE NOTICE 'PASS: deactivation writes an admin_audit row and leaves the member''s saved_recipes row completely untouched';

  ------------------------------------------------- f. anon has no EXECUTE on any of the four
  IF has_function_privilege('anon', 'public.admin_list_recipes(text, text, boolean, int, int)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_list_recipes';
  END IF;
  IF has_function_privilege('anon', 'public.admin_recipe_detail(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_recipe_detail';
  END IF;
  IF has_function_privilege('anon', 'public.admin_upsert_recipe(text, uuid, text, integer, integer, integer, jsonb, jsonb, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_upsert_recipe';
  END IF;
  IF has_function_privilege('anon', 'public.admin_set_recipe_active(uuid, boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_set_recipe_active';
  END IF;
  RAISE NOTICE 'PASS: anon holds no EXECUTE on any of the four admin recipe RPCs';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
