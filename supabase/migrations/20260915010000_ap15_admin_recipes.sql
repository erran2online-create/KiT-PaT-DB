-- ---------------------------------------------------------------------------
-- AP15: admin read and curation of the recipe library. Run after
-- 20260914020000_p46_recipes.sql (merged) -- that migration was read in
-- full first for the exact recipes/saved_recipes shape:
--   recipes: id, normalized_key, title, cuisine, serves, prep_minutes,
--   cook_minutes, ingredients jsonb, steps jsonb, notes, source
--   ('seeded'|'ai'), ai_provider, ai_model, is_active, hit_count,
--   created_at, last_hit_at. No client write policy of any kind -- only
--   service_role (get-recipe) and P46's own RPCs write it.
--
-- AP7 pattern throughout: SECURITY DEFINER, is_admin()-guarded, KITPAT_*
-- codes, GRANT authenticated + service_role, REVOKE EXECUTE FROM anon.
-- Reads (admin_list_recipes/admin_recipe_detail) are any active admin,
-- KITPAT_ADMIN_ONLY only. Writes (admin_upsert_recipe/admin_set_recipe_
-- active) are owner/org_admin only -- two separate checks, two separate
-- codes (KITPAT_ADMIN_ONLY for a non-admin, KITPAT_INSUFFICIENT_ROLE for
-- an active admin whose role is 'member'), mirroring AP14's admin_set_
-- feature_flag and AP12's admin_delete_food_cache_entry. Audited via
-- log_admin_action, called directly with the admin's own JWT -- the AP7.2
-- guard fix (is_admin() OR is_service) makes this succeed the same way
-- every other direct-JWT admin write in this repo already does.
--
-- NO HARD DELETION, per the task: a recipe a member has saved must not
-- vanish from her collection (saved_recipes.recipe_id REFERENCES
-- recipes(id) ON DELETE CASCADE -- a hard delete would silently wipe it
-- out of every member's Saved list with no trace). admin_set_recipe_active
-- is the one safety valve: deactivating hides a wrong recipe from
-- find_recipe and from recipes_select_active browsing immediately,
-- without touching any saved_recipes row or breaking its FK. No delete
-- RPC of any kind is added here.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. admin_list_recipes -- any active admin. p_search matches title
--    (ILIKE, substring); p_source/p_active are NULL-means-"any" filters.
--    Ordered by hit_count desc -- the most-asked-for recipes surface
--    first, useful for spotting what to double-check.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_recipes(
  p_search text DEFAULT NULL,
  p_source text DEFAULT NULL,
  p_active boolean DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
) RETURNS TABLE (
  id uuid,
  title text,
  cuisine text,
  serves integer,
  source text,
  ai_provider text,
  ai_model text,
  is_active boolean,
  hit_count integer,
  created_at timestamptz,
  last_hit_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  RETURN QUERY
  SELECT r.id, r.title, r.cuisine, r.serves, r.source, r.ai_provider, r.ai_model,
         r.is_active, r.hit_count, r.created_at, r.last_hit_at
  FROM public.recipes r
  WHERE (p_search IS NULL OR r.title ILIKE '%' || p_search || '%')
    AND (p_source IS NULL OR r.source = p_source)
    AND (p_active IS NULL OR r.is_active = p_active)
  ORDER BY r.hit_count DESC, r.created_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.admin_list_recipes(text, text, boolean, int, int) IS
  'Any active admin. Every recipe (optionally title-searched, source- and active-filtered), ordered by hit_count desc. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_recipes(text, text, boolean, int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_list_recipes(text, text, boolean, int, int) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_recipes(text, text, boolean, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. admin_recipe_detail -- any active admin. The full row, including
--    ingredients/steps and inactive recipes (no is_active filter -- an
--    admin needs to see a deactivated recipe to review or reactivate it).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_recipe_detail(p_recipe_id uuid)
RETURNS public.recipes
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  row_out public.recipes;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  SELECT * INTO row_out FROM public.recipes WHERE id = p_recipe_id;
  IF row_out.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  RETURN row_out;
END;
$$;

COMMENT ON FUNCTION public.admin_recipe_detail(uuid) IS
  'Any active admin. The full recipe row, including ingredients/steps and inactive recipes. Errors: KITPAT_ADMIN_ONLY / KITPAT_NOT_FOUND.';

REVOKE ALL ON FUNCTION public.admin_recipe_detail(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_recipe_detail(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_recipe_detail(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. admin_upsert_recipe -- owner/org_admin only, audited. p_recipe_id
--    NULL creates a new recipe (source is always 'seeded' -- admin-
--    authored); given, edits it in place and unconditionally sets
--    source = 'seeded', whatever it was before -- once a human has
--    written or corrected the content, it is curated, not disposable
--    cache, and must never be silently overwritten again by a future
--    get-recipe cache-fill for the same title. normalized_key is
--    recomputed from p_title on every call (create or edit), matching
--    the table's own normalized_key = normalize_food_key(title) rule;
--    a title that would collide with a DIFFERENT existing recipe's key
--    is rejected with KITPAT_DUPLICATE_TITLE rather than surfacing a raw
--    unique_violation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_upsert_recipe(
  p_title text,
  p_recipe_id uuid DEFAULT NULL,
  p_cuisine text DEFAULT NULL,
  p_serves integer DEFAULT NULL,
  p_prep_minutes integer DEFAULT NULL,
  p_cook_minutes integer DEFAULT NULL,
  p_ingredients jsonb DEFAULT '[]'::jsonb,
  p_steps jsonb DEFAULT '[]'::jsonb,
  p_notes text DEFAULT NULL
) RETURNS public.recipes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_admin_id uuid;
  caller_email text;
  before_row jsonb;
  row_out public.recipes;
  v_key text;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;
  IF public.admin_role() NOT IN ('owner', 'org_admin') THEN
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
  END IF;

  IF coalesce(btrim(p_title), '') = '' THEN
    RAISE EXCEPTION 'KITPAT_TITLE_REQUIRED' USING ERRCODE = 'PT400';
  END IF;

  v_key := public.normalize_food_key(p_title);
  IF v_key = '' THEN
    RAISE EXCEPTION 'KITPAT_TITLE_REQUIRED' USING ERRCODE = 'PT400';
  END IF;

  IF p_recipe_id IS NOT NULL THEN
    SELECT to_jsonb(r) INTO before_row FROM public.recipes r WHERE r.id = p_recipe_id;
    IF before_row IS NULL THEN
      RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM public.recipes WHERE normalized_key = v_key AND id IS DISTINCT FROM p_recipe_id) THEN
    RAISE EXCEPTION 'KITPAT_DUPLICATE_TITLE' USING ERRCODE = 'PT409';
  END IF;

  IF p_recipe_id IS NULL THEN
    INSERT INTO public.recipes (
      normalized_key, title, cuisine, serves, prep_minutes, cook_minutes,
      ingredients, steps, notes, source
    ) VALUES (
      v_key, btrim(p_title), p_cuisine, p_serves, p_prep_minutes, p_cook_minutes,
      coalesce(p_ingredients, '[]'::jsonb), coalesce(p_steps, '[]'::jsonb), p_notes, 'seeded'
    )
    RETURNING * INTO row_out;
  ELSE
    UPDATE public.recipes SET
      normalized_key = v_key,
      title = btrim(p_title),
      cuisine = p_cuisine,
      serves = p_serves,
      prep_minutes = p_prep_minutes,
      cook_minutes = p_cook_minutes,
      ingredients = coalesce(p_ingredients, '[]'::jsonb),
      steps = coalesce(p_steps, '[]'::jsonb),
      notes = p_notes,
      source = 'seeded'
    WHERE id = p_recipe_id
    RETURNING * INTO row_out;
  END IF;

  caller_email := auth.jwt() ->> 'email';
  SELECT id INTO caller_admin_id FROM public.admins WHERE email = caller_email AND is_active = true;

  PERFORM public.log_admin_action(
    CASE WHEN p_recipe_id IS NULL THEN 'create:recipe' ELSE 'update:recipe' END,
    'recipes', row_out.id::text, before_row, to_jsonb(row_out), false, NULL, NULL, caller_admin_id, caller_email
  );

  RETURN row_out;
END;
$$;

COMMENT ON FUNCTION public.admin_upsert_recipe(text, uuid, text, integer, integer, integer, jsonb, jsonb, text) IS
  'Owner/org_admin only (member admins rejected). p_recipe_id NULL creates (source=seeded); given, edits in place and unconditionally sets source=seeded -- once a human has touched it, it is curated content, never treated as disposable AI cache again. normalized_key is recomputed from p_title every call. Audited via log_admin_action. Errors: KITPAT_ADMIN_ONLY / KITPAT_INSUFFICIENT_ROLE / KITPAT_TITLE_REQUIRED / KITPAT_NOT_FOUND / KITPAT_DUPLICATE_TITLE.';

REVOKE ALL ON FUNCTION public.admin_upsert_recipe(text, uuid, text, integer, integer, integer, jsonb, jsonb, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_upsert_recipe(text, uuid, text, integer, integer, integer, jsonb, jsonb, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_upsert_recipe(text, uuid, text, integer, integer, integer, jsonb, jsonb, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. admin_set_recipe_active -- owner/org_admin only, audited. The one
--    safety valve: deactivating hides a wrong recipe from find_recipe and
--    from recipes_select_active immediately, without hard-deleting it --
--    saved_recipes rows already pointing at it are completely unaffected
--    (recipes.id is untouched; only is_active flips).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_recipe_active(p_recipe_id uuid, p_active boolean)
RETURNS public.recipes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_admin_id uuid;
  caller_email text;
  before_row jsonb;
  row_out public.recipes;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;
  IF public.admin_role() NOT IN ('owner', 'org_admin') THEN
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
  END IF;

  SELECT to_jsonb(r) INTO before_row FROM public.recipes r WHERE r.id = p_recipe_id;
  IF before_row IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  UPDATE public.recipes
  SET is_active = coalesce(p_active, false)
  WHERE id = p_recipe_id
  RETURNING * INTO row_out;

  caller_email := auth.jwt() ->> 'email';
  SELECT id INTO caller_admin_id FROM public.admins WHERE email = caller_email AND is_active = true;

  PERFORM public.log_admin_action(
    'set_active:recipe', 'recipes', p_recipe_id::text, before_row, to_jsonb(row_out), false, NULL, NULL, caller_admin_id, caller_email
  );

  RETURN row_out;
END;
$$;

COMMENT ON FUNCTION public.admin_set_recipe_active(uuid, boolean) IS
  'Owner/org_admin only (member admins rejected). Flips is_active -- the safety valve for a wrong recipe, without hard-deleting it (a member''s saved_recipes row must never vanish). Audited via log_admin_action. Errors: KITPAT_ADMIN_ONLY / KITPAT_INSUFFICIENT_ROLE / KITPAT_NOT_FOUND.';

REVOKE ALL ON FUNCTION public.admin_set_recipe_active(uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_recipe_active(uuid, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_recipe_active(uuid, boolean) TO authenticated, service_role;
