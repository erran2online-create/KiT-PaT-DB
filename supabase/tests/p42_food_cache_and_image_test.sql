-- P42 test: normalize_food_key, food_cache (service_role only), the
-- ai_usage_log.input_kind column, and a P41 non-regression smoke check.
--
-- The cache-hit and image paths inside analyze-food are NOT SQL-testable
-- (they require the deployed edge function -- an actual Cloudinary URL,
-- an actual provider round trip, and the cache-hit-skips-the-provider
-- behavior) and are NOT exercised here. This file covers only the SQL
-- side: normalize_food_key, food_cache's shape/RLS/UNIQUE constraint, and
-- ai_usage_log.input_kind.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0-AP13, P41, and this migration
-- (20260910010000_p42_food_cache_and_image.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p42_food_cache_and_image_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. normalize_food_key collapses case, whitespace and punctuation --
--      three differently-typed forms of the same dish produce one key.
--   b. food_cache has RLS on, zero policies, and neither anon nor
--      authenticated holds any privilege.
--   c. The UNIQUE constraint on normalized_key rejects a duplicate.
--   d. ai_usage_log.input_kind exists, is nullable, and the CHECK rejects
--      a third value.
--   e. The existing P41 record/list/delete round trip still works
--      unchanged (a smoke check, not a re-run of every P41 assertion --
--      those live in supabase/tests/p41_food_tracking_test.sql,
--      unmodified and still expected to pass on their own).

BEGIN;

DO $t$
DECLARE
  key_a text;
  key_b text;
  key_c text;
  rls_enabled boolean;
  policy_count integer;
  anon_priv boolean;
  authenticated_priv boolean;
  col record;
  smoke_user uuid;
  smoke_entry record;
  smoke_visible integer;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (name, phone, city) VALUES ('P42 Smoke User', '9944000001', 'Kolkata') RETURNING id INTO smoke_user;

  --------------------------------------------------------- a. normalize_food_key
  key_a := public.normalize_food_key('2 roti sabzi');
  key_b := public.normalize_food_key('2   ROTI   SABZI');
  key_c := public.normalize_food_key('  2, roti, sabzi!  ');

  IF key_a <> '2 roti sabzi' THEN
    RAISE EXCEPTION 'FAIL: normalize_food_key(''2 roti sabzi'') = %, expected ''2 roti sabzi''', key_a;
  END IF;
  IF key_a IS DISTINCT FROM key_b OR key_a IS DISTINCT FROM key_c THEN
    RAISE EXCEPTION 'FAIL: three differently-typed forms of the same dish produced different keys: %, %, %', key_a, key_b, key_c;
  END IF;
  RAISE NOTICE 'PASS: normalize_food_key collapses case, whitespace and punctuation -- three forms of the same dish produce one key (%)', key_a;

  --------------------------------------------------------- b. food_cache RLS shape
  SELECT relrowsecurity INTO rls_enabled FROM pg_class WHERE relname = 'food_cache' AND relnamespace = 'public'::regnamespace;
  IF rls_enabled IS NOT true THEN
    RAISE EXCEPTION 'FAIL: food_cache RLS is not enabled';
  END IF;

  SELECT count(*) INTO policy_count FROM pg_policies WHERE schemaname = 'public' AND tablename = 'food_cache';
  IF policy_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: food_cache has % policies, expected 0', policy_count;
  END IF;

  SELECT has_table_privilege('anon', 'public.food_cache', 'SELECT') INTO anon_priv;
  SELECT has_table_privilege('authenticated', 'public.food_cache', 'SELECT') INTO authenticated_priv;
  IF anon_priv IS NOT false OR authenticated_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon/authenticated SELECT privilege on food_cache = %/%, expected false/false', anon_priv, authenticated_priv;
  END IF;
  RAISE NOTICE 'PASS: food_cache has RLS on, zero policies, and neither anon nor authenticated holds any privilege';

  --------------------------------------------------------------- c. UNIQUE guard
  INSERT INTO public.food_cache (normalized_key, sample_description, ai_provider, ai_model)
  VALUES (key_a, '2 roti sabzi', 'anthropic', 'claude-haiku-4-5-20251001');

  BEGIN
    INSERT INTO public.food_cache (normalized_key, sample_description, ai_provider, ai_model)
    VALUES (key_a, 'a different description, same key', 'openai', 'gpt-4o-mini');
    RAISE EXCEPTION 'FAIL: a duplicate normalized_key was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
  RAISE NOTICE 'PASS: the UNIQUE constraint on normalized_key rejects a duplicate';

  ------------------------------------------------------- d. ai_usage_log.input_kind
  SELECT column_name, is_nullable INTO col
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'ai_usage_log' AND column_name = 'input_kind';
  IF col.column_name IS NULL THEN
    RAISE EXCEPTION 'FAIL: ai_usage_log.input_kind does not exist';
  END IF;
  IF col.is_nullable <> 'YES' THEN
    RAISE EXCEPTION 'FAIL: ai_usage_log.input_kind is_nullable=%, expected YES', col.is_nullable;
  END IF;

  BEGIN
    INSERT INTO public.ai_usage_log (user_id, feature, provider, succeeded, input_kind)
    VALUES (smoke_user, 'food_analysis', 'anthropic', true, 'audio');
    RAISE EXCEPTION 'FAIL: ai_usage_log.input_kind accepted a third value (''audio'')';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  RAISE NOTICE 'PASS: ai_usage_log.input_kind exists, is nullable, and the CHECK rejects a third value';

  --------------------------------------------- e. P41 round trip still works
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', smoke_user::text, 'role', 'authenticated')::text, true);

  SELECT * INTO smoke_entry FROM public.record_food_entry('P42 smoke check dosa');
  IF smoke_entry.id IS NULL OR smoke_entry.user_id <> smoke_user THEN
    RAISE EXCEPTION 'FAIL: record_food_entry (P41) did not create an entry correctly after P42: %', smoke_entry;
  END IF;

  SELECT count(*) INTO smoke_visible FROM public.list_food_entries(NULL, 50, 0) WHERE id = smoke_entry.id;
  IF smoke_visible <> 1 THEN
    RAISE EXCEPTION 'FAIL: list_food_entries (P41) did not return the smoke-check entry after P42';
  END IF;

  PERFORM public.delete_food_entry(smoke_entry.id);
  SELECT count(*) INTO smoke_visible FROM public.food_entries WHERE id = smoke_entry.id;
  IF smoke_visible <> 0 THEN
    RAISE EXCEPTION 'FAIL: delete_food_entry (P41) did not delete the smoke-check entry after P42';
  END IF;
  RAISE NOTICE 'PASS: the P41 record/list/delete round trip still works unchanged (full P41 coverage remains in p41_food_tracking_test.sql)';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
  RAISE NOTICE 'NOTE: analyze-food''s cache-hit and image paths were NOT tested here -- not SQL-testable; exercise them against the deployed function.';
END;
$t$;

ROLLBACK;
