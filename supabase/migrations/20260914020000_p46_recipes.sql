-- ---------------------------------------------------------------------------
-- P46: recipes. After a food lookup, a member can tap "Recipe" to see how
-- to make the dish, save it to her own collection, and share it.
--
-- 20260909040000_p41_food_tracking.sql and 20260910010000_p42_food_cache_
-- and_image.sql were both read in full before writing this. This feature
-- reuses public.normalize_food_key (P42) as-is -- untouched -- and mirrors
-- food_cache's design: a normalized-key library that is checked first
-- (free, instant, no provider call) before ever paying for an AI call.
-- food_entries, food_cache, analyze-food and normalize_food_key itself are
-- not modified by this migration.
--
-- Two tables:
--   recipes -- the shared library. Two sources: seeded by an admin
--     (source='seeded', 12 rows below) or AI-generated on a miss and then
--     kept (source='ai', written by the get-recipe edge function only).
--     normalized_key = normalize_food_key(title) (not of the member's raw
--     search description) -- this is an explicit design point, flagged
--     rather than silently changed: get-recipe's prompt asks the provider
--     for a clean, canonical dish title (not an echo of whatever the
--     member typed), and the library is keyed on that title. In the
--     common case a member's search phrase normalizes to the same key as
--     the resulting title (e.g. "chana masala" -> title "Chana Masala" ->
--     same key), so "the next member asking gets it free" holds. If a
--     member's phrasing is unusual enough that it normalizes differently
--     from the canonical title the AI produces, that specific phrasing
--     will miss the library again on a later identical search and
--     generate a second AI lookup (get-recipe's own ON CONFLICT handling,
--     see that file, means this never produces a duplicate row for the
--     same canonical title -- only an extra provider call for the
--     differently-phrased search). Not fixed here since the table's exact
--     key formula was specified directly in the task.
--   saved_recipes -- the member's own collection (Profile > Saved). Unlike
--     recipes (service_role/RPC write only), this table also has direct
--     owner-scoped RLS write policies, per the task -- both a direct
--     client write and save_recipe/unsave_recipe (which add idempotency
--     and a KITPAT_NOT_FOUND signal a raw client INSERT/DELETE can't give
--     for free) are valid paths to the same rule.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. recipes
-- ---------------------------------------------------------------------------
CREATE TABLE public.recipes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalized_key text NOT NULL UNIQUE,
  title text NOT NULL,
  cuisine text,
  serves integer,
  prep_minutes integer,
  cook_minutes integer,
  ingredients jsonb NOT NULL DEFAULT '[]'::jsonb,
  steps jsonb NOT NULL DEFAULT '[]'::jsonb,
  notes text,
  source text NOT NULL CHECK (source IN ('seeded', 'ai')),
  ai_provider text,
  ai_model text,
  is_active boolean NOT NULL DEFAULT true,
  hit_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_hit_at timestamptz
);

COMMENT ON TABLE public.recipes IS
  'Shared recipe library, keyed on normalize_food_key(title). source=seeded (admin-authored) or ai (written once by get-recipe on a first miss, then free for every later matching search). No client write policy of any kind -- only service_role and this migration''s RPCs (find_recipe/save_recipe/unsave_recipe/list_saved_recipes, all SECURITY DEFINER) ever write it.';
COMMENT ON COLUMN public.recipes.ingredients IS 'Array of {item, quantity}.';
COMMENT ON COLUMN public.recipes.steps IS 'Ordered array of instruction strings.';
COMMENT ON COLUMN public.recipes.is_active IS 'False hides a recipe from find_recipe/browsing without deleting it (and without breaking any saved_recipes row already pointing at it).';

ALTER TABLE public.recipes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS recipes_select_active ON public.recipes;
CREATE POLICY recipes_select_active ON public.recipes
  FOR SELECT TO authenticated
  USING (is_active = true);

-- Deliberately no INSERT/UPDATE/DELETE policy of any kind: writes go
-- through service_role (get-recipe) or the SECURITY DEFINER RPCs below.

REVOKE ALL ON public.recipes FROM anon;
GRANT SELECT ON public.recipes TO authenticated;
GRANT ALL ON public.recipes TO service_role;

-- ---------------------------------------------------------------------------
-- 2. saved_recipes -- owner-only collection.
-- ---------------------------------------------------------------------------
CREATE TABLE public.saved_recipes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  recipe_id uuid NOT NULL REFERENCES public.recipes(id) ON DELETE CASCADE,
  saved_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, recipe_id)
);

COMMENT ON TABLE public.saved_recipes IS
  'A member''s own saved-recipe collection (Profile > Saved). Owner-only: RLS restricts every command to user_id = auth.uid(). save_recipe/unsave_recipe additionally give idempotency and a stable KITPAT_NOT_FOUND, but a direct client INSERT/DELETE satisfying the same RLS rule is equally valid.';

CREATE INDEX idx_saved_recipes_user ON public.saved_recipes (user_id, saved_at DESC);

ALTER TABLE public.saved_recipes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS saved_recipes_select_own ON public.saved_recipes;
CREATE POLICY saved_recipes_select_own ON public.saved_recipes
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS saved_recipes_insert_own ON public.saved_recipes;
CREATE POLICY saved_recipes_insert_own ON public.saved_recipes
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS saved_recipes_delete_own ON public.saved_recipes;
CREATE POLICY saved_recipes_delete_own ON public.saved_recipes
  FOR DELETE TO authenticated
  USING (user_id = auth.uid());

REVOKE ALL ON public.saved_recipes FROM anon;
GRANT SELECT, INSERT, DELETE ON public.saved_recipes TO authenticated;
GRANT ALL ON public.saved_recipes TO service_role;

-- ---------------------------------------------------------------------------
-- 3. find_recipe -- matches an active recipe by normalize_food_key(p_
--    description). SETOF, not a scalar: zero rows on a miss is a normal
--    result, not an error (mirrors food_cache's own "a miss is not a
--    failure" shape). Bumps hit_count/last_hit_at on a hit, same pattern
--    as analyze-food's cache-hit bump.
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

  SELECT * INTO rec FROM public.recipes WHERE normalized_key = v_key AND is_active = true;
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
  'Matches an active recipe by normalize_food_key(p_description). Zero rows on a miss -- not an error, the caller (or get-recipe) should try an AI lookup next. Bumps hit_count/last_hit_at on a hit. Errors: KITPAT_UNAUTHENTICATED.';

REVOKE ALL ON FUNCTION public.find_recipe(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.find_recipe(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.find_recipe(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. save_recipe -- idempotent (ON CONFLICT DO NOTHING, never an error on
--    re-save). Rejects a recipe id that doesn't exist or isn't active --
--    a member can only ever have discovered one through find_recipe/
--    get-recipe, both of which only ever surface active rows.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_recipe(p_recipe_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.recipes WHERE id = p_recipe_id AND is_active = true) THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  INSERT INTO public.saved_recipes (user_id, recipe_id)
  VALUES (uid, p_recipe_id)
  ON CONFLICT (user_id, recipe_id) DO NOTHING;
END;
$$;

COMMENT ON FUNCTION public.save_recipe(uuid) IS
  'Idempotent: saving an already-saved recipe is a silent no-op, never an error. Errors: KITPAT_UNAUTHENTICATED / KITPAT_NOT_FOUND (recipe does not exist or is not active).';

REVOKE ALL ON FUNCTION public.save_recipe(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.save_recipe(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_recipe(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. unsave_recipe -- KITPAT_NOT_FOUND covers both "never saved" and
--    "already unsaved", indistinguishable to the caller (same pattern as
--    delete_food_entry).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.unsave_recipe(p_recipe_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  deleted_id uuid;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;

  DELETE FROM public.saved_recipes
  WHERE user_id = uid AND recipe_id = p_recipe_id
  RETURNING id INTO deleted_id;

  IF deleted_id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.unsave_recipe(uuid) IS
  'Owner-only. KITPAT_NOT_FOUND whether the recipe was never saved or already unsaved. Errors: KITPAT_UNAUTHENTICATED / KITPAT_NOT_FOUND.';

REVOKE ALL ON FUNCTION public.unsave_recipe(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.unsave_recipe(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.unsave_recipe(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. list_saved_recipes -- the caller's own collection (Profile > Saved),
--    newest-saved first. Returns full recipe content (not just an id) so
--    the screen can render each card without a second round trip.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_saved_recipes(p_limit int DEFAULT 50, p_offset int DEFAULT 0)
RETURNS TABLE (
  recipe_id uuid,
  title text,
  cuisine text,
  serves integer,
  prep_minutes integer,
  cook_minutes integer,
  ingredients jsonb,
  steps jsonb,
  notes text,
  saved_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;

  RETURN QUERY
  SELECT r.id, r.title, r.cuisine, r.serves, r.prep_minutes, r.cook_minutes, r.ingredients, r.steps, r.notes, sr.saved_at
  FROM public.saved_recipes sr
  JOIN public.recipes r ON r.id = sr.recipe_id
  WHERE sr.user_id = uid
  ORDER BY sr.saved_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.list_saved_recipes(int, int) IS
  'The caller''s own saved-recipe collection, newest-saved first, with full recipe content joined in. Errors: KITPAT_UNAUTHENTICATED.';

REVOKE ALL ON FUNCTION public.list_saved_recipes(int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.list_saved_recipes(int, int) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_saved_recipes(int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Seed 12 recipes for dishes an Indian kitty group actually serves.
--    source='seeded' -- these exist before any AI call is ever made, so
--    the library path (find_recipe hitting without get-recipe running) is
--    provable from a fresh database. Titles double as normalized_key's
--    input; ON CONFLICT (normalized_key) DO NOTHING makes this safe to
--    re-run.
-- ---------------------------------------------------------------------------
INSERT INTO public.recipes (normalized_key, title, cuisine, serves, prep_minutes, cook_minutes, ingredients, steps, notes, source)
VALUES
  (public.normalize_food_key('Chana Masala'), 'Chana Masala', 'North Indian', 4, 10, 25,
   '[{"item":"chickpeas (boiled)","quantity":"2 cups"},{"item":"onion, chopped","quantity":"1 large"},{"item":"tomato, pureed","quantity":"2 medium"},{"item":"ginger-garlic paste","quantity":"1 tbsp"},{"item":"chana masala powder","quantity":"2 tsp"},{"item":"oil","quantity":"2 tbsp"}]'::jsonb,
   '["Heat oil, saute onion until golden.","Add ginger-garlic paste, cook 1 minute.","Add tomato puree and chana masala powder, cook until oil separates.","Add boiled chickpeas and a splash of water, simmer 10 minutes.","Season with salt and garnish with coriander."]'::jsonb,
   'A kitty-party staple: filling, easy to scale up, and holds well in a chafing dish.', 'seeded'),

  (public.normalize_food_key('Paneer Butter Masala'), 'Paneer Butter Masala', 'North Indian', 4, 15, 25,
   '[{"item":"paneer, cubed","quantity":"300 g"},{"item":"butter","quantity":"3 tbsp"},{"item":"tomato puree","quantity":"2 cups"},{"item":"cashew paste","quantity":"2 tbsp"},{"item":"cream","quantity":"2 tbsp"},{"item":"kasuri methi","quantity":"1 tsp"}]'::jsonb,
   '["Melt butter, add tomato puree and cashew paste, cook 10 minutes.","Add spices and simmer until the gravy thickens.","Add paneer cubes and cream, simmer 5 minutes.","Finish with crushed kasuri methi."]'::jsonb,
   'The crowd-pleaser -- keep it mild by default since it usually feeds the whole table.', 'seeded'),

  (public.normalize_food_key('Veg Biryani'), 'Veg Biryani', 'Hyderabadi', 6, 25, 40,
   '[{"item":"basmati rice","quantity":"3 cups"},{"item":"mixed vegetables","quantity":"3 cups"},{"item":"yogurt","quantity":"1 cup"},{"item":"fried onions","quantity":"1 cup"},{"item":"biryani masala","quantity":"2 tbsp"},{"item":"mint and coriander leaves","quantity":"1 cup"}]'::jsonb,
   '["Parboil the rice with whole spices until 70% cooked.","Marinate vegetables in yogurt and biryani masala for 20 minutes.","Layer marinated vegetables and rice in a heavy pot with fried onions and herbs.","Cover tightly and cook on dum (low heat) for 25 minutes.","Rest 10 minutes before opening and fluffing."]'::jsonb,
   'A full meal on its own -- popular when the group wants one big dish instead of several sides.', 'seeded'),

  (public.normalize_food_key('Dal Makhani'), 'Dal Makhani', 'Punjabi', 6, 15, 45,
   '[{"item":"whole black urad dal","quantity":"1 cup"},{"item":"rajma","quantity":"1/4 cup"},{"item":"butter","quantity":"3 tbsp"},{"item":"cream","quantity":"1/4 cup"},{"item":"tomato puree","quantity":"1 cup"},{"item":"ginger-garlic paste","quantity":"1 tbsp"}]'::jsonb,
   '["Pressure-cook soaked dal and rajma until soft.","Saute ginger-garlic paste, add tomato puree, cook until thick.","Add the cooked dal, simmer at least 30 minutes, mashing some for creaminess.","Finish with butter and cream."]'::jsonb,
   'Tastes better the longer it simmers -- good to start early if it''s on the menu.', 'seeded'),

  (public.normalize_food_key('Pav Bhaji'), 'Pav Bhaji', 'Mumbai street food', 6, 15, 25,
   '[{"item":"mixed vegetables (potato, peas, capsicum, cauliflower)","quantity":"4 cups, mashed"},{"item":"pav bhaji masala","quantity":"3 tbsp"},{"item":"butter","quantity":"4 tbsp"},{"item":"onion, chopped","quantity":"2"},{"item":"tomato, chopped","quantity":"3"},{"item":"pav (bread rolls)","quantity":"12"}]'::jsonb,
   '["Boil and mash the mixed vegetables.","Saute onion and tomato in butter, add pav bhaji masala.","Add the mashed vegetables and simmer, mashing further while cooking.","Toast the pav in butter on a griddle.","Serve the bhaji hot with buttered pav, chopped onion and a lemon wedge."]'::jsonb,
   'Fast, cheap, and easy to keep warm for a rolling buffet.', 'seeded'),

  (public.normalize_food_key('Aloo Paratha'), 'Aloo Paratha', 'Punjabi', 4, 20, 20,
   '[{"item":"whole wheat flour","quantity":"2 cups"},{"item":"boiled potato, mashed","quantity":"2 cups"},{"item":"green chili, chopped","quantity":"1"},{"item":"ajwain","quantity":"1/2 tsp"},{"item":"ghee","quantity":"as needed"}]'::jsonb,
   '["Knead a soft dough with the flour and water.","Mix mashed potato with chili, ajwain and salt for the stuffing.","Roll dough into a disc, stuff with potato mixture, seal and roll out again.","Cook on a hot griddle with ghee until golden on both sides."]'::jsonb,
   'Best fresh off the griddle -- pair with curd and pickle.', 'seeded'),

  (public.normalize_food_key('Chicken Biryani'), 'Chicken Biryani', 'Hyderabadi', 6, 30, 45,
   '[{"item":"basmati rice","quantity":"3 cups"},{"item":"chicken, curry cut","quantity":"1 kg"},{"item":"yogurt","quantity":"1 cup"},{"item":"fried onions","quantity":"1 cup"},{"item":"biryani masala","quantity":"3 tbsp"},{"item":"mint and coriander leaves","quantity":"1 cup"}]'::jsonb,
   '["Marinate chicken in yogurt, biryani masala and half the fried onions for at least 1 hour.","Parboil the rice with whole spices.","Layer marinated chicken and rice in a heavy pot with remaining onions and herbs.","Cover tightly and cook on dum (low heat) for 30-35 minutes.","Rest 10 minutes before opening and fluffing gently from the sides."]'::jsonb,
   'The showpiece dish for a bigger celebration -- needs the most lead time on this list.', 'seeded'),

  (public.normalize_food_key('Butter Chicken'), 'Butter Chicken', 'North Indian', 4, 20, 30,
   '[{"item":"chicken, boneless","quantity":"500 g"},{"item":"butter","quantity":"3 tbsp"},{"item":"tomato puree","quantity":"2 cups"},{"item":"cream","quantity":"3 tbsp"},{"item":"kasuri methi","quantity":"1 tsp"},{"item":"garam masala","quantity":"1 tsp"}]'::jsonb,
   '["Marinate and grill or pan-sear the chicken until just cooked.","Cook tomato puree in butter until it darkens and the oil separates.","Add garam masala, simmer, then add the cooked chicken.","Finish with cream and crushed kasuri methi."]'::jsonb,
   'Keep it on the milder side by default -- easy to add chili for anyone who wants more heat.', 'seeded'),

  (public.normalize_food_key('Vegetable Pulao'), 'Vegetable Pulao', 'North Indian', 4, 10, 20,
   '[{"item":"basmati rice","quantity":"2 cups"},{"item":"mixed vegetables","quantity":"1.5 cups"},{"item":"whole spices (bay leaf, cinnamon, cloves)","quantity":"1 set"},{"item":"ghee","quantity":"2 tbsp"}]'::jsonb,
   '["Saute whole spices in ghee until fragrant.","Add vegetables, saute 2-3 minutes.","Add rice and water, bring to a boil.","Cover and cook on low heat until the rice is done and water is absorbed."]'::jsonb,
   'The simplest one-pot option when the group wants something light alongside a heavier main.', 'seeded'),

  (public.normalize_food_key('Gulab Jamun'), 'Gulab Jamun', 'North Indian', 8, 15, 20,
   '[{"item":"khoya (milk solids)","quantity":"1 cup"},{"item":"maida","quantity":"2 tbsp"},{"item":"sugar","quantity":"2 cups"},{"item":"cardamom powder","quantity":"1/2 tsp"},{"item":"ghee or oil (for frying)","quantity":"as needed"}]'::jsonb,
   '["Knead khoya and maida into a smooth, crack-free dough.","Shape into small smooth balls.","Fry on low-medium heat until deep golden brown, turning gently.","Make a sugar syrup with cardamom, and soak the fried balls in warm syrup for at least 30 minutes."]'::jsonb,
   'The default dessert for almost any party -- can be made a day ahead, it only improves.', 'seeded'),

  (public.normalize_food_key('Rava Kesari'), 'Rava Kesari', 'South Indian', 6, 5, 15,
   '[{"item":"semolina (rava)","quantity":"1 cup"},{"item":"sugar","quantity":"1 cup"},{"item":"ghee","quantity":"1/4 cup"},{"item":"water","quantity":"2.5 cups"},{"item":"saffron or orange food color","quantity":"a pinch"},{"item":"cashews and raisins","quantity":"2 tbsp"}]'::jsonb,
   '["Roast semolina in ghee until aromatic, without browning.","Boil water with saffron/color, pour into the roasted semolina carefully, stirring constantly.","Cook until the mixture thickens and leaves the sides of the pan.","Add sugar, mix until it melts in and the ghee separates again.","Garnish with ghee-fried cashews and raisins."]'::jsonb,
   'Quick enough to make last-minute if the dessert plan falls through.', 'seeded'),

  (public.normalize_food_key('Samosa'), 'Samosa', 'North Indian', 6, 30, 25,
   '[{"item":"all-purpose flour","quantity":"2 cups"},{"item":"boiled potato, mashed","quantity":"3 cups"},{"item":"green peas","quantity":"1/2 cup"},{"item":"cumin seeds","quantity":"1 tsp"},{"item":"garam masala","quantity":"1 tsp"},{"item":"oil (for frying)","quantity":"as needed"}]'::jsonb,
   '["Make a stiff dough with flour, a little oil and water; rest 20 minutes.","Cook potato, peas and spices together for the filling.","Roll dough into ovals, cut in half, shape into cones and fill.","Seal the edges with a little water and deep-fry on medium heat until golden and crisp."]'::jsonb,
   'The classic tea-time snack for whenever guests arrive before the main meal is ready.', 'seeded')
ON CONFLICT (normalized_key) DO NOTHING;
