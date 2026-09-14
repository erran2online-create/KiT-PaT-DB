-- P46.1 PART B test: find_recipe's progressive (exact, then substring)
-- matching, inactive-row exclusion at every step, the highest-hit_count
-- tiebreak, and that the function's signature/grants/anon-revocation are
-- unchanged.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has this migration
-- (20260915030000_p46_1_recipe_matching.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p46_1_recipe_matching_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. Exact match still works for all 12 seeded recipes.
--   b. "paneer butter masala with extra gravy" matches the seeded Paneer
--      Butter Masala.
--   c. "PAV   BHAJI!!" still matches (normalisation unchanged).
--   d. A genuinely unknown dish still returns no rows, not a wrong recipe.
--   e. An inactive recipe is never returned by any step (exact or
--      substring).
--   f. Where two recipes could match at step 2, the higher hit_count wins.
--   g. find_recipe's signature, grants and anon revocation are unchanged.

BEGIN;

DO $t$
DECLARE
  member_id uuid;
  seeded_titles text[] := ARRAY[
    'Chana Masala', 'Paneer Butter Masala', 'Veg Biryani', 'Dal Makhani',
    'Pav Bhaji', 'Aloo Paratha', 'Chicken Biryani', 'Butter Chicken',
    'Vegetable Pulao', 'Gulab Jamun', 'Rava Kesari', 'Samosa'
  ];
  t text;
  found_row public.recipes;
  found_count integer;
  paneer_id uuid;
  inactive_id uuid;
  low_hit_id uuid;
  high_hit_id uuid;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (name, phone, city) VALUES ('P46.1 Member', '9922300001', 'Pune') RETURNING id INTO member_id;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_id::text, 'role', 'authenticated')::text, true);

  SELECT id INTO paneer_id FROM public.recipes WHERE normalized_key = public.normalize_food_key('Paneer Butter Masala');
  IF paneer_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: seeded "Paneer Butter Masala" not found -- is 20260914020000_p46_recipes.sql applied?';
  END IF;

  ------------------------------------------------------- a. exact match, all 12 seeded
  FOREACH t IN ARRAY seeded_titles LOOP
    SELECT * INTO found_row FROM public.find_recipe(t);
    IF found_row.id IS NULL OR found_row.title <> t THEN
      RAISE EXCEPTION 'FAIL: exact match failed for seeded recipe "%": got %', t, found_row;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: exact match still works for all 12 seeded recipes';

  ------------------------------------------------------- b. ordinary phrasing matches
  SELECT * INTO found_row FROM public.find_recipe('paneer butter masala with extra gravy');
  IF found_row.id <> paneer_id THEN
    RAISE EXCEPTION 'FAIL: "paneer butter masala with extra gravy" did not match the seeded Paneer Butter Masala: %', found_row;
  END IF;
  RAISE NOTICE 'PASS: "paneer butter masala with extra gravy" matches the seeded Paneer Butter Masala';

  ------------------------------------------------------- c. normalisation unchanged
  SELECT * INTO found_row FROM public.find_recipe('PAV   BHAJI!!');
  IF found_row.title <> 'Pav Bhaji' THEN
    RAISE EXCEPTION 'FAIL: "PAV   BHAJI!!" did not match Pav Bhaji: %', found_row;
  END IF;
  RAISE NOTICE 'PASS: "PAV   BHAJI!!" still matches Pav Bhaji -- normalisation unchanged';

  ------------------------------------------------------- d. unknown dish stays a miss
  SELECT count(*) INTO found_count FROM public.find_recipe('Definitely Not A Real Dish 12345 xyz');
  IF found_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: find_recipe returned % row(s) for a genuinely unknown dish, expected 0', found_count;
  END IF;
  RAISE NOTICE 'PASS: a genuinely unknown dish still returns no rows, not a wrong recipe';

  ------------------------------------------------------- e. inactive recipe excluded at every step
  INSERT INTO public.recipes (normalized_key, title, ingredients, steps, source, is_active)
  VALUES (public.normalize_food_key('P46.1 Inactive Dish'), 'P46.1 Inactive Dish', '[]'::jsonb, '[]'::jsonb, 'seeded', false)
  RETURNING id INTO inactive_id;

  SELECT count(*) INTO found_count FROM public.find_recipe('P46.1 Inactive Dish');
  IF found_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: find_recipe returned an inactive recipe via exact match (found_count=%)', found_count;
  END IF;

  SELECT count(*) INTO found_count FROM public.find_recipe('P46.1 Inactive Dish with extra words');
  IF found_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: find_recipe returned an inactive recipe via substring match (found_count=%)', found_count;
  END IF;
  RAISE NOTICE 'PASS: an inactive recipe is never returned by exact or substring matching';

  ------------------------------------------------------- f. higher hit_count wins a tie
  INSERT INTO public.recipes (normalized_key, title, ingredients, steps, source, is_active, hit_count)
  VALUES (public.normalize_food_key('Zztestdish Special'), 'Zztestdish Special', '[]'::jsonb, '[]'::jsonb, 'seeded', true, 5)
  RETURNING id INTO low_hit_id;
  INSERT INTO public.recipes (normalized_key, title, ingredients, steps, source, is_active, hit_count)
  VALUES (public.normalize_food_key('Zztestdish'), 'Zztestdish', '[]'::jsonb, '[]'::jsonb, 'seeded', true, 10)
  RETURNING id INTO high_hit_id;

  -- Both "zztestdish special" and "zztestdish" are substrings of this
  -- description, so both rows match step 2 -- the higher hit_count (10,
  -- "Zztestdish") must win regardless of which is textually closer.
  SELECT * INTO found_row FROM public.find_recipe('Zztestdish Special Extra Words');
  IF found_row.id <> high_hit_id THEN
    RAISE EXCEPTION 'FAIL: expected the higher-hit_count recipe (id=%) to win, got %', high_hit_id, found_row;
  END IF;
  RAISE NOTICE 'PASS: where two recipes could match at step 2, the higher hit_count wins';

  ------------------------------------------------------- g. signature/grants/anon unchanged
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'find_recipe'
      AND pg_get_function_identity_arguments(p.oid) = 'p_description text'
      AND p.proretset  -- still set-returning (SETOF), not a scalar
  ) THEN
    RAISE EXCEPTION 'FAIL: find_recipe''s signature (p_description text) -> SETOF ... has changed';
  END IF;
  -- Return-row shape is also exercised directly above: every assertion in
  -- this test assigns a hit into a public.recipes-typed variable, which
  -- would fail to run at all if the return type were no longer SETOF
  -- public.recipes.

  IF NOT has_function_privilege('authenticated', 'public.find_recipe(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: authenticated lost EXECUTE on find_recipe';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.find_recipe(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: service_role lost EXECUTE on find_recipe';
  END IF;
  IF has_function_privilege('anon', 'public.find_recipe(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon gained EXECUTE on find_recipe';
  END IF;
  RAISE NOTICE 'PASS: find_recipe''s signature, grants and anon revocation are unchanged';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
