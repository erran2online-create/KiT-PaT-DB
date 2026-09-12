-- AP12 test: admin_list_food_entries, admin_food_entry_detail,
-- admin_ai_usage_summary, admin_list_food_cache, and
-- admin_delete_food_cache_entry.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has P41/P41.1/P42 and this migration
-- (20260910030000_ap12_admin_food_read.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap12_admin_food_read_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. Each of the four read RPCs raises KITPAT_ADMIN_ONLY for a non-admin.
--   b. Each returns rows for an active admin against seeded fixtures.
--   c. admin_delete_food_cache_entry raises KITPAT_INSUFFICIENT_ROLE for a
--      'member' admin and succeeds for an owner.
--   d. A successful cache deletion writes an admin_audit row.
--   e. anon holds no EXECUTE on any of the five.
--   f. A member's own access to food_entries is unchanged.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap12.owner.test@kitpat.in';
  member_admin_email text := 'ap12.memberadmin.test@kitpat.in';
  non_admin_email text := 'ap12.notadmin.test@kitpat.in';
  member_user_id uuid;
  outsider_user_id uuid;
  group_id uuid;
  personal_entry_id uuid;
  shared_entry_id uuid;
  cache_id uuid;
  err text;
  row_rec record;
  found_row boolean;
  anon_priv boolean;
  audit_count_before integer;
  audit_count_after integer;
  own_visible_count integer;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES
    (owner_email, 'owner', true),
    (member_admin_email, 'member', true)
  ON CONFLICT (email) DO UPDATE SET role = EXCLUDED.role, is_active = true;

  INSERT INTO public.users (name, phone, city) VALUES ('AP12 Member', '9933000001', 'Bengaluru') RETURNING id INTO member_user_id;
  INSERT INTO public.users (name, phone, city) VALUES ('AP12 Outsider', '9933000002', 'Bengaluru') RETURNING id INTO outsider_user_id;

  INSERT INTO public.groups (name, host_id, city) VALUES ('AP12 Test Group ' || substr(gen_random_uuid()::text, 1, 8), member_user_id, 'Bengaluru') RETURNING id INTO group_id;
  INSERT INTO public.members (group_id, user_id, role) VALUES (group_id, member_user_id, 'host');

  INSERT INTO public.food_entries (user_id, group_id, description, serving, calories_kcal, protein_g, fat_g, carbs_g, ai_provider, ai_model, ai_raw)
  VALUES (member_user_id, NULL, 'AP12 personal dosa', '1 piece', 150, 4, 5, 20, 'anthropic', 'claude-haiku-4-5-20251001', '{"raw":"personal"}'::jsonb)
  RETURNING id INTO personal_entry_id;

  INSERT INTO public.food_entries (user_id, group_id, description, serving, calories_kcal, protein_g, fat_g, carbs_g, ai_provider, ai_model, ai_raw)
  VALUES (member_user_id, group_id, 'AP12 shared biryani', '1 plate', 600, 25, 20, 70, 'openai', 'gpt-4o-mini', '{"raw":"shared"}'::jsonb)
  RETURNING id INTO shared_entry_id;

  INSERT INTO public.ai_usage_log (user_id, feature, provider, model, succeeded, input_kind) VALUES
    (member_user_id, 'food_analysis', 'anthropic', 'claude-haiku-4-5-20251001', true, 'text'),
    (member_user_id, 'food_analysis', 'anthropic', 'claude-haiku-4-5-20251001', false, 'text'),
    (member_user_id, 'food_analysis', 'openai', 'gpt-4o-mini', true, 'image');

  INSERT INTO public.food_cache (normalized_key, sample_description, serving, calories_kcal, protein_g, fat_g, carbs_g, ai_provider, ai_model, hit_count)
  VALUES ('ap12 test cache key', 'AP12 cached dish', '1 bowl', 300, 10, 8, 40, 'anthropic', 'claude-haiku-4-5-20251001', 7)
  RETURNING id INTO cache_id;

  --------------------------------------------------------- a. KITPAT_ADMIN_ONLY
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', non_admin_email, 'role', 'authenticated')::text, true);

  BEGIN
    PERFORM * FROM public.admin_list_food_entries();
    RAISE EXCEPTION 'FAIL: admin_list_food_entries succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_list_food_entries raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;

  BEGIN
    PERFORM * FROM public.admin_food_entry_detail(personal_entry_id);
    RAISE EXCEPTION 'FAIL: admin_food_entry_detail succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_food_entry_detail raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;

  BEGIN
    PERFORM * FROM public.admin_ai_usage_summary();
    RAISE EXCEPTION 'FAIL: admin_ai_usage_summary succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_ai_usage_summary raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;

  BEGIN
    PERFORM * FROM public.admin_list_food_cache();
    RAISE EXCEPTION 'FAIL: admin_list_food_cache succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_list_food_cache raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: each of the four read RPCs raises KITPAT_ADMIN_ONLY for a non-admin';

  ------------------------------------------------------- b. active admin: rows
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);

  SELECT * INTO row_rec FROM public.admin_list_food_entries(NULL, NULL, NULL, 100, 0) WHERE id = shared_entry_id;
  IF row_rec.id IS NULL OR row_rec.member_name <> 'AP12 Member' OR row_rec.group_name IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_list_food_entries did not return the shared fixture entry with resolved member/group names: %', row_rec;
  END IF;

  SELECT * INTO row_rec FROM public.admin_list_food_entries(NULL, NULL, NULL, 100, 0) WHERE id = personal_entry_id;
  IF row_rec.id IS NULL OR row_rec.group_name IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: admin_list_food_entries showed a group_name for a personal entry: %', row_rec;
  END IF;

  SELECT * INTO row_rec FROM public.admin_food_entry_detail(shared_entry_id);
  IF row_rec.id IS NULL OR (row_rec.ai_raw ->> 'raw') <> 'shared' THEN
    RAISE EXCEPTION 'FAIL: admin_food_entry_detail did not return ai_raw correctly: %', row_rec;
  END IF;

  SELECT bool_or(succeeded_count = 1 AND failed_count = 1 AND input_kind = 'text') INTO found_row
  FROM public.admin_ai_usage_summary(NULL, NULL)
  WHERE user_id = member_user_id AND provider = 'anthropic';
  IF NOT coalesce(found_row, false) THEN
    RAISE EXCEPTION 'FAIL: admin_ai_usage_summary did not correctly roll up the fixture text rows (1 succeeded, 1 failed)';
  END IF;
  SELECT bool_or(succeeded_count = 1 AND input_kind = 'image') INTO found_row
  FROM public.admin_ai_usage_summary(NULL, NULL)
  WHERE user_id = member_user_id AND provider = 'openai';
  IF NOT coalesce(found_row, false) THEN
    RAISE EXCEPTION 'FAIL: admin_ai_usage_summary did not correctly roll up the fixture image row';
  END IF;

  SELECT * INTO row_rec FROM public.admin_list_food_cache(NULL, 100, 0) WHERE id = cache_id;
  IF row_rec.id IS NULL OR row_rec.hit_count <> 7 THEN
    RAISE EXCEPTION 'FAIL: admin_list_food_cache did not return the fixture cache row correctly: %', row_rec;
  END IF;
  RAISE NOTICE 'PASS: each read RPC returns correct rows for an active admin against the fixtures';

  ----------------------------------------------- c. admin_delete_food_cache_entry role gate
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', member_admin_email, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.admin_delete_food_cache_entry(cache_id);
    RAISE EXCEPTION 'FAIL: admin_delete_food_cache_entry succeeded for a member admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN
      RAISE EXCEPTION 'FAIL: member-admin admin_delete_food_cache_entry raised "%", expected KITPAT_INSUFFICIENT_ROLE', err;
    END IF;
  END;

  SELECT count(*) INTO audit_count_before FROM public.admin_audit WHERE action = 'delete:food_cache' AND target_id = cache_id::text;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  PERFORM public.admin_delete_food_cache_entry(cache_id);

  IF EXISTS (SELECT 1 FROM public.food_cache WHERE id = cache_id) THEN
    RAISE EXCEPTION 'FAIL: admin_delete_food_cache_entry did not actually delete the cache row';
  END IF;
  RAISE NOTICE 'PASS: admin_delete_food_cache_entry raises KITPAT_INSUFFICIENT_ROLE for a member admin and succeeds for an owner';

  --------------------------------------------------------- d. admin_audit row
  SELECT count(*) INTO audit_count_after FROM public.admin_audit WHERE action = 'delete:food_cache' AND target_id = cache_id::text;
  IF audit_count_after <= audit_count_before THEN
    RAISE EXCEPTION 'FAIL: the successful cache deletion did not write an admin_audit row';
  END IF;
  RAISE NOTICE 'PASS: a successful cache deletion writes an admin_audit row';

  ------------------------------------------------------------------ e. anon lockout
  SELECT has_function_privilege('anon', 'public.admin_list_food_entries(text,uuid,uuid,int,int)', 'EXECUTE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_list_food_entries';
  END IF;
  SELECT has_function_privilege('anon', 'public.admin_food_entry_detail(uuid)', 'EXECUTE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_food_entry_detail';
  END IF;
  SELECT has_function_privilege('anon', 'public.admin_ai_usage_summary(date,date)', 'EXECUTE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_ai_usage_summary';
  END IF;
  SELECT has_function_privilege('anon', 'public.admin_list_food_cache(text,int,int)', 'EXECUTE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_list_food_cache';
  END IF;
  SELECT has_function_privilege('anon', 'public.admin_delete_food_cache_entry(uuid)', 'EXECUTE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_delete_food_cache_entry';
  END IF;
  RAISE NOTICE 'PASS: anon holds no EXECUTE on any of the five functions';

  -------------------------------------------------- f. member's own access unchanged
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_user_id::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO own_visible_count FROM public.food_entries WHERE id IN (personal_entry_id, shared_entry_id);
  RESET ROLE;
  IF own_visible_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: the member could not see their own two food_entries rows via ordinary RLS (count=%)', own_visible_count;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', outsider_user_id::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO own_visible_count FROM public.food_entries WHERE id = personal_entry_id;
  RESET ROLE;
  IF own_visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: an unrelated user could see another member''s personal food_entries row (count=%), expected 0 -- RLS should be unchanged', own_visible_count;
  END IF;
  RAISE NOTICE 'PASS: a member''s own access to food_entries (existing RLS) is unchanged';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
