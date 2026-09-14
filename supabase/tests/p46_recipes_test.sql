-- P46 test: the 12 seeded recipes, find_recipe's normalized matching and
-- inactive-row exclusion, save_recipe/unsave_recipe, saved_recipes RLS,
-- and anon's total lack of privilege on either table or the four RPCs.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has this migration
-- (20260914020000_p46_recipes.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p46_recipes_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. The 12 seeded recipes exist and find_recipe matches one by a
--      differently cased/spaced description.
--   b. find_recipe on an unknown dish returns no rows (not an error).
--   c. save_recipe is idempotent; a second call does not error or
--      duplicate.
--   d. A member cannot read another member's saved_recipes.
--   e. unsave_recipe raises KITPAT_NOT_FOUND for a recipe she never saved.
--   f. An inactive recipe is not returned by find_recipe.
--   g. anon holds no privilege on either table and no EXECUTE on the four
--      RPCs.

BEGIN;

DO $t$
DECLARE
  member_a_id uuid;
  member_b_id uuid;
  chana_id uuid;
  inactive_id uuid;
  err text;
  seeded_count integer;
  found_row public.recipes;
  found_count integer;
  saved_count integer;
  visible_count integer;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (name, phone, city) VALUES ('P46 Member A', '9922100001', 'Pune') RETURNING id INTO member_a_id;
  INSERT INTO public.users (name, phone, city) VALUES ('P46 Member B', '9922100002', 'Pune') RETURNING id INTO member_b_id;

  ------------------------------------------------------- a. seeded recipes + match
  SELECT count(*) INTO seeded_count FROM public.recipes WHERE source = 'seeded';
  IF seeded_count <> 12 THEN
    RAISE EXCEPTION 'FAIL: expected exactly 12 seeded recipes, found %', seeded_count;
  END IF;

  SELECT id INTO chana_id FROM public.recipes WHERE normalized_key = public.normalize_food_key('Chana Masala');
  IF chana_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: seeded recipe "Chana Masala" not found';
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_a_id::text, 'role', 'authenticated')::text, true);
  SELECT * INTO found_row FROM public.find_recipe('  CHANA   masala  ');
  IF found_row.id <> chana_id THEN
    RAISE EXCEPTION 'FAIL: find_recipe did not match "Chana Masala" from a differently cased/spaced description: %', found_row;
  END IF;
  IF found_row.hit_count < 1 THEN
    RAISE EXCEPTION 'FAIL: find_recipe did not bump hit_count on a hit (hit_count=%)', found_row.hit_count;
  END IF;
  RAISE NOTICE 'PASS: all 12 seeded recipes exist and find_recipe matches "Chana Masala" from a differently cased/spaced description, bumping hit_count';

  ------------------------------------------------------- b. unknown dish is not an error
  SELECT count(*) INTO found_count FROM public.find_recipe('Definitely Not A Real Dish 12345 xyz');
  IF found_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: find_recipe returned % row(s) for an unknown dish, expected 0', found_count;
  END IF;
  RAISE NOTICE 'PASS: find_recipe on an unknown dish returns no rows, not an error';

  ------------------------------------------------------- c. save_recipe idempotent
  PERFORM public.save_recipe(chana_id);
  PERFORM public.save_recipe(chana_id);
  SELECT count(*) INTO saved_count FROM public.saved_recipes WHERE user_id = member_a_id AND recipe_id = chana_id;
  IF saved_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: save_recipe called twice produced % rows, expected exactly 1', saved_count;
  END IF;
  RAISE NOTICE 'PASS: save_recipe is idempotent -- a second call does not error or duplicate';

  ------------------------------------------------------- d. saved_recipes RLS
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_b_id::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO visible_count FROM public.saved_recipes WHERE user_id = member_a_id;
  RESET ROLE;
  IF visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: member B can see member A''s saved_recipes row(s) (visible_count=%)', visible_count;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_a_id::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO visible_count FROM public.saved_recipes WHERE user_id = member_a_id;
  RESET ROLE;
  IF visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: member A cannot see her own saved_recipes row via direct RLS-scoped SELECT (visible_count=%)', visible_count;
  END IF;
  RAISE NOTICE 'PASS: a member cannot read another member''s saved_recipes, but can read her own';

  ------------------------------------------------------- e. unsave_recipe KITPAT_NOT_FOUND
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_b_id::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.unsave_recipe(chana_id);
    RAISE EXCEPTION 'FAIL: unsave_recipe succeeded for a recipe member B never saved';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_FOUND' THEN
      RAISE EXCEPTION 'FAIL: unsave_recipe on a never-saved recipe raised "%", expected KITPAT_NOT_FOUND', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: unsave_recipe raises KITPAT_NOT_FOUND for a recipe the caller never saved';

  ------------------------------------------------------- f. inactive recipe excluded
  INSERT INTO public.recipes (normalized_key, title, ingredients, steps, source, is_active)
  VALUES (public.normalize_food_key('P46 Inactive Test Dish'), 'P46 Inactive Test Dish', '[]'::jsonb, '[]'::jsonb, 'seeded', false)
  RETURNING id INTO inactive_id;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_a_id::text, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO found_count FROM public.find_recipe('P46 Inactive Test Dish');
  IF found_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: find_recipe returned an inactive recipe (found_count=%)', found_count;
  END IF;
  RAISE NOTICE 'PASS: an inactive recipe is not returned by find_recipe';

  ------------------------------------------------------- g. anon has no privilege
  IF has_table_privilege('anon', 'public.recipes', 'SELECT')
     OR has_table_privilege('anon', 'public.recipes', 'INSERT')
     OR has_table_privilege('anon', 'public.recipes', 'UPDATE')
     OR has_table_privilege('anon', 'public.recipes', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: anon holds some privilege on public.recipes';
  END IF;
  IF has_table_privilege('anon', 'public.saved_recipes', 'SELECT')
     OR has_table_privilege('anon', 'public.saved_recipes', 'INSERT')
     OR has_table_privilege('anon', 'public.saved_recipes', 'UPDATE')
     OR has_table_privilege('anon', 'public.saved_recipes', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: anon holds some privilege on public.saved_recipes';
  END IF;
  IF has_function_privilege('anon', 'public.find_recipe(text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.save_recipe(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.unsave_recipe(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.list_saved_recipes(int, int)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on at least one of the four recipe RPCs';
  END IF;
  RAISE NOTICE 'PASS: anon holds no privilege on recipes or saved_recipes, and no EXECUTE on any of the four RPCs';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
