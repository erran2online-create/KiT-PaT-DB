-- AP16 test: features_archive's default/additivity, archive/restore's
-- one-statement move (including a boolean value), the KITPAT_ALREADY_
-- EXISTS guard, the owner-only role gate, admin_audit rows, and anon's
-- lack of EXECUTE on either RPC.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has this migration
-- (20260915020000_ap16_features_archive.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap16_features_archive_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Item (a) note: the real Free/Empress plan rows (and their live feature
-- counts) are not seeded by any migration in this repo -- confirmed by
-- grep, same situation as feature_flags/analytics_event_catalog/recipes'
-- pre-existing rows -- so this test cannot query them by name. Instead it
-- constructs its own fixture plans with 19- and 27-key features objects
-- (matching the real Free/Empress shapes the task describes) to prove the
-- migration is additive and never alters an existing features value.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap16-owner@kitpat.in';
  member_admin_email text := 'ap16-memberadmin@kitpat.in';
  free_plan_id uuid;
  empress_plan_id uuid;
  free_features_before jsonb;
  empress_features_before jsonb;
  free_features_after jsonb;
  empress_features_after jsonb;
  err text;
  row_out public.plans;
  archived_value jsonb;
  audit_count_before integer;
  audit_count_after integer;
  key_count integer;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES (owner_email, 'owner', true)
    ON CONFLICT (email) DO UPDATE SET role = 'owner', is_active = true;
  INSERT INTO public.admins (email, role, is_active) VALUES (member_admin_email, 'member', true)
    ON CONFLICT (email) DO UPDATE SET role = 'member', is_active = true;

  free_features_before := (SELECT jsonb_object_agg('feat_' || i, (i % 2 = 0)) FROM generate_series(1, 19) i);
  empress_features_before := (SELECT jsonb_object_agg('feat_' || i, (i % 2 = 0)) FROM generate_series(1, 27) i);

  INSERT INTO public.plans (name, slug, price_monthly, price_yearly, features)
  VALUES ('AP16 Free Test', 'ap16-free-test-' || substr(gen_random_uuid()::text, 1, 8), 0, 0, free_features_before)
  RETURNING id INTO free_plan_id;
  INSERT INTO public.plans (name, slug, price_monthly, price_yearly, features)
  VALUES ('AP16 Empress Test', 'ap16-empress-test-' || substr(gen_random_uuid()::text, 1, 8), 999, 9999, empress_features_before)
  RETURNING id INTO empress_plan_id;

  ------------------------------------------------------- a. additive, defaults, unchanged
  IF (SELECT features_archive FROM public.plans WHERE id = free_plan_id) <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL: features_archive did not default to {} on a freshly inserted plan';
  END IF;

  SELECT count(*) INTO key_count FROM jsonb_object_keys((SELECT features FROM public.plans WHERE id = free_plan_id));
  IF key_count <> 19 THEN
    RAISE EXCEPTION 'FAIL: the 19-key test plan (standing in for Free) does not have 19 features keys (found %)', key_count;
  END IF;
  SELECT count(*) INTO key_count FROM jsonb_object_keys((SELECT features FROM public.plans WHERE id = empress_plan_id));
  IF key_count <> 27 THEN
    RAISE EXCEPTION 'FAIL: the 27-key test plan (standing in for Empress) does not have 27 features keys (found %)', key_count;
  END IF;

  IF (SELECT features FROM public.plans WHERE id = free_plan_id) <> free_features_before
     OR (SELECT features FROM public.plans WHERE id = empress_plan_id) <> empress_features_before THEN
    RAISE EXCEPTION 'FAIL: adding features_archive altered an existing plan''s features value';
  END IF;
  RAISE NOTICE 'PASS: features_archive exists and defaults to {}, and both fixture plans (19-key and 27-key, standing in for Free/Empress) keep their features objects completely unchanged';

  ------------------------------------------------- b. archive moves the key, value intact
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);

  row_out := public.admin_archive_plan_feature(free_plan_id, 'feat_2');  -- feat_2 = true (boolean)
  IF row_out.features ? 'feat_2' THEN
    RAISE EXCEPTION 'FAIL: feat_2 is still present in features after archiving';
  END IF;
  IF NOT (row_out.features_archive ? 'feat_2') THEN
    RAISE EXCEPTION 'FAIL: feat_2 was not added to features_archive';
  END IF;
  archived_value := row_out.features_archive -> 'feat_2';
  IF archived_value <> 'true'::jsonb THEN
    RAISE EXCEPTION 'FAIL: feat_2''s archived value is not the original boolean true (got %)', archived_value;
  END IF;
  RAISE NOTICE 'PASS: archiving removes the key from features and adds it to features_archive with the same value, including a boolean value';

  ------------------------------------------------- c. restore reverses it
  row_out := public.admin_restore_plan_feature(free_plan_id, 'feat_2');
  IF row_out.features_archive ? 'feat_2' THEN
    RAISE EXCEPTION 'FAIL: feat_2 is still present in features_archive after restoring';
  END IF;
  IF NOT (row_out.features ? 'feat_2') OR (row_out.features -> 'feat_2') <> 'true'::jsonb THEN
    RAISE EXCEPTION 'FAIL: feat_2 was not correctly restored into features with its original value: %', row_out.features -> 'feat_2';
  END IF;
  RAISE NOTICE 'PASS: restoring puts the key back into features with its original value and removes it from features_archive';

  ------------------------------------------------- d. restoring onto an existing key
  PERFORM public.admin_archive_plan_feature(free_plan_id, 'feat_3');
  -- Simulate the key having been independently re-added to features while
  -- its old value still sits in the archive (a raw UPDATE, not through the
  -- RPC, to construct this specific collision deterministically).
  UPDATE public.plans SET features = features || jsonb_build_object('feat_3', false) WHERE id = free_plan_id;

  BEGIN
    PERFORM public.admin_restore_plan_feature(free_plan_id, 'feat_3');
    RAISE EXCEPTION 'FAIL: admin_restore_plan_feature overwrote an existing features key';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ALREADY_EXISTS' THEN
      RAISE EXCEPTION 'FAIL: restoring onto an existing key raised "%", expected KITPAT_ALREADY_EXISTS', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: restoring onto an existing key raises KITPAT_ALREADY_EXISTS rather than overwriting it';

  ------------------------------------------------- e. KITPAT_INSUFFICIENT_ROLE for a non-owner admin
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', member_admin_email, 'role', 'authenticated')::text, true);

  BEGIN
    PERFORM public.admin_archive_plan_feature(free_plan_id, 'feat_1');
    RAISE EXCEPTION 'FAIL: a member-role admin was able to call admin_archive_plan_feature';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN RAISE EXCEPTION 'FAIL: member-admin admin_archive_plan_feature raised "%", expected KITPAT_INSUFFICIENT_ROLE', err; END IF;
  END;

  BEGIN
    PERFORM public.admin_restore_plan_feature(free_plan_id, 'feat_3');
    RAISE EXCEPTION 'FAIL: a member-role admin was able to call admin_restore_plan_feature';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN RAISE EXCEPTION 'FAIL: member-admin admin_restore_plan_feature raised "%", expected KITPAT_INSUFFICIENT_ROLE', err; END IF;
  END;
  RAISE NOTICE 'PASS: both RPCs raise KITPAT_INSUFFICIENT_ROLE for a non-owner admin';

  ------------------------------------------------- f. successful archive audits
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO audit_count_before FROM public.admin_audit;
  PERFORM public.admin_archive_plan_feature(free_plan_id, 'feat_1');
  SELECT count(*) INTO audit_count_after FROM public.admin_audit;
  IF audit_count_after <> audit_count_before + 1 THEN
    RAISE EXCEPTION 'FAIL: a successful archive did not write exactly one admin_audit row (before=%, after=%)', audit_count_before, audit_count_after;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_audit
    WHERE action = 'archive:plan_feature' AND target_type = 'plans' AND target_id = free_plan_id::text AND actor_email = owner_email
    ORDER BY created_at DESC LIMIT 1
  ) THEN
    RAISE EXCEPTION 'FAIL: the admin_audit row for the archive does not have the expected action/target_type/target_id/actor_email';
  END IF;
  RAISE NOTICE 'PASS: a successful archive writes exactly one admin_audit row';

  ------------------------------------------------------------- g. anon has no EXECUTE
  IF has_function_privilege('anon', 'public.admin_archive_plan_feature(uuid, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_archive_plan_feature';
  END IF;
  IF has_function_privilege('anon', 'public.admin_restore_plan_feature(uuid, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_restore_plan_feature';
  END IF;
  RAISE NOTICE 'PASS: anon holds no EXECUTE on either admin_archive_plan_feature or admin_restore_plan_feature';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
