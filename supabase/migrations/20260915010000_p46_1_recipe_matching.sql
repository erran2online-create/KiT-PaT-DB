-- ---------------------------------------------------------------------------
-- P46.1 PART B: find_recipe progressive matching.
--
-- CORRECTION to P46 (20260914020000_p46_recipes.sql, already applied and
-- therefore never edited): recipes.normalized_key is built from the
-- recipe's TITLE, so an exact-match-only find_recipe missed ordinary human
-- phrasing -- "paneer butter masala with extra gravy" would not match the
-- seeded "Paneer Butter Masala" and would trigger a needless AI call. That
-- defeats the point of having a library. Flagged and confirmed; fixed here
-- with exactly two matching steps, cheapest first, stopping at the first
-- hit -- no fuzzy matching, trigram similarity, stemming or synonyms (they
-- need real search data this repo does not have, and a wrong recipe
-- served confidently is worse than an AI call):
--
--   1. Exact match on normalize_food_key(p_description) -- as today.
--   2. Substring match either direction: the normalized description
--      CONTAINS a recipe's normalized_key, OR a recipe's normalized_key
--      CONTAINS the normalized description. Where more than one recipe
--      matches, the one with the highest hit_count wins (ties broken by
--      created_at, oldest first, so LIMIT 1 is deterministic rather than
--      picking an arbitrary row).
--   3. Still nothing -> zero rows, exactly as today -- a miss is not an
--      error, and get-recipe is the caller's next step, not this
--      function's problem.
--
-- CREATE OR REPLACE with find_recipe's exact existing signature
-- (p_description text) -> SETOF public.recipes -- no GRANT/REVOKE
-- statements here, deliberately: an identical signature does not alter a
-- function's existing ACL in Postgres, so it keeps exactly the grants it
-- already had (authenticated + service_role, anon revoked, from P46).
-- recipes, saved_recipes, normalize_food_key, food_cache and every RLS
-- policy are untouched.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.find_recipe(p_description text)
RETURNS SETOF public.recipes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  v_key text;
  rec public.recipes;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;

  v_key := public.normalize_food_key(p_description);
  IF v_key = '' THEN
    RETURN;
  END IF;

  -- Step 1: exact match, as today.
  SELECT * INTO rec FROM public.recipes WHERE normalized_key = v_key AND is_active = true;

  -- Step 2: only tried if step 1 missed. normalize_food_key never produces
  -- '%' or '_' (its regex keeps only a-z, 0-9, '.' and single spaces), so
  -- these LIKE patterns need no escaping.
  IF rec.id IS NULL THEN
    SELECT * INTO rec
    FROM public.recipes
    WHERE is_active = true
      AND (v_key LIKE '%' || normalized_key || '%' OR normalized_key LIKE '%' || v_key || '%')
    ORDER BY hit_count DESC, created_at ASC
    LIMIT 1;
  END IF;

  -- Step 3: still nothing -- a miss, not an error.
  IF rec.id IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.recipes
  SET hit_count = hit_count + 1, last_hit_at = now()
  WHERE id = rec.id
  RETURNING * INTO rec;

  RETURN NEXT rec;
END;
$$;

COMMENT ON FUNCTION public.find_recipe(text) IS
  'Matches an active recipe in two steps, cheapest first, stopping at the first hit: (1) exact match on normalize_food_key(p_description), (2) substring match either direction between the normalized description and a recipe''s normalized_key, highest hit_count wins a tie. Zero rows if neither step hits -- not an error, the caller (or get-recipe) should try an AI lookup next. Bumps hit_count/last_hit_at on any hit. No fuzzy matching, trigram similarity, stemming or synonyms -- deliberately out of scope. Errors: KITPAT_UNAUTHENTICATED.';
