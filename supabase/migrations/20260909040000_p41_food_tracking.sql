-- ---------------------------------------------------------------------------
-- P41: food tracking. A member describes a food or beverage in text; an AI
-- (analyze-food edge function) returns approximate macros; the entry is
-- saved via record_food_entry. Personal by default (group_id NULL); can
-- optionally be shared to one group. NOT a health/medical feature, NOT a
-- photo/vision feature -- text description in, approximate estimate out.
--
-- Macro columns stay NULLable at the table level (an entry may be saved
-- before/without an AI estimate), but every RPC below returns 0 plus a
-- separate has_macros flag rather than a raw NULL for any of them, per
-- this repo's standing "never a bare null for a number the UI displays"
-- rule.
--
-- record_food_entry/list_food_entries/delete_food_entry are SECURITY
-- DEFINER and therefore bypass RLS -- each one replicates the exact same
-- ownership/group-membership rule the table's own RLS policies enforce,
-- so the two enforcement paths (a direct client write and the RPC) can
-- never drift apart. No UPDATE policy or RPC: an entry is corrected by
-- deleting and re-adding.
-- ---------------------------------------------------------------------------

CREATE TABLE public.food_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  group_id uuid REFERENCES public.groups(id) ON DELETE SET NULL,
  media_id uuid REFERENCES public.media(id),
  description text NOT NULL,
  serving text,
  calories_kcal numeric,
  protein_g numeric,
  fat_g numeric,
  carbs_g numeric,
  ai_provider text,
  ai_model text,
  ai_raw jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_estimate boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT food_entries_description_not_blank CHECK (btrim(description) <> ''),
  CONSTRAINT food_entries_ai_provider_check CHECK (ai_provider IS NULL OR ai_provider IN ('openai', 'anthropic'))
);

COMMENT ON TABLE public.food_entries IS
  'Member-logged food/beverage entries: a text description, optional AI-estimated macros, personal by default (group_id NULL) or shared to one group. Not a health/medical feature. Written only via record_food_entry/delete_food_entry (or a direct client write satisfying the same RLS rule); never updated in place.';
COMMENT ON COLUMN public.food_entries.group_id IS
  'NULL = personal (only the owner can read it). Set = shared with that group -- any member of it can read the entry.';
COMMENT ON COLUMN public.food_entries.ai_raw IS
  'Full raw provider response, for debugging/audit. Defaults to {} for an entry saved without an AI call.';

CREATE INDEX idx_food_entries_user ON public.food_entries (user_id, created_at DESC);
CREATE INDEX idx_food_entries_group ON public.food_entries (group_id, created_at DESC) WHERE group_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
ALTER TABLE public.food_entries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS food_entries_select ON public.food_entries;
CREATE POLICY food_entries_select ON public.food_entries
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR (group_id IS NOT NULL AND public.is_group_member(group_id, auth.uid()))
  );

DROP POLICY IF EXISTS food_entries_insert ON public.food_entries;
CREATE POLICY food_entries_insert ON public.food_entries
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    AND (group_id IS NULL OR public.is_group_member(group_id, auth.uid()))
  );

DROP POLICY IF EXISTS food_entries_delete ON public.food_entries;
CREATE POLICY food_entries_delete ON public.food_entries
  FOR DELETE TO authenticated
  USING (user_id = auth.uid());

-- No UPDATE policy at all: an entry is corrected by deleting and re-adding.

REVOKE ALL ON public.food_entries FROM anon;
GRANT SELECT, INSERT, DELETE ON public.food_entries TO authenticated;
GRANT ALL ON public.food_entries TO service_role;

-- ---------------------------------------------------------------------------
-- record_food_entry -- the caller's own entry only (user_id is always
-- auth.uid(), never a parameter); if group_id is given the caller must
-- already be a member of that group.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_food_entry(
  p_description text,
  p_serving text DEFAULT NULL,
  p_group_id uuid DEFAULT NULL,
  p_media_id uuid DEFAULT NULL,
  p_calories_kcal numeric DEFAULT NULL,
  p_protein_g numeric DEFAULT NULL,
  p_fat_g numeric DEFAULT NULL,
  p_carbs_g numeric DEFAULT NULL,
  p_ai_provider text DEFAULT NULL,
  p_ai_model text DEFAULT NULL,
  p_ai_raw jsonb DEFAULT '{}'::jsonb
) RETURNS TABLE (
  id uuid,
  user_id uuid,
  group_id uuid,
  media_id uuid,
  description text,
  serving text,
  calories_kcal numeric,
  protein_g numeric,
  fat_g numeric,
  carbs_g numeric,
  has_macros boolean,
  is_estimate boolean,
  ai_provider text,
  ai_model text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  row public.food_entries;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;
  IF coalesce(btrim(p_description), '') = '' THEN
    RAISE EXCEPTION 'KITPAT_DESCRIPTION_REQUIRED' USING ERRCODE = 'PT400';
  END IF;
  IF p_group_id IS NOT NULL AND NOT public.is_group_member(p_group_id, uid) THEN
    RAISE EXCEPTION 'KITPAT_NOT_GROUP_MEMBER' USING ERRCODE = 'PT403';
  END IF;

  INSERT INTO public.food_entries (
    user_id, group_id, media_id, description, serving,
    calories_kcal, protein_g, fat_g, carbs_g,
    ai_provider, ai_model, ai_raw
  ) VALUES (
    uid, p_group_id, p_media_id, p_description, p_serving,
    p_calories_kcal, p_protein_g, p_fat_g, p_carbs_g,
    p_ai_provider, p_ai_model, coalesce(p_ai_raw, '{}'::jsonb)
  )
  RETURNING * INTO row;

  RETURN QUERY SELECT
    row.id, row.user_id, row.group_id, row.media_id, row.description, row.serving,
    coalesce(row.calories_kcal, 0), coalesce(row.protein_g, 0), coalesce(row.fat_g, 0), coalesce(row.carbs_g, 0),
    (row.calories_kcal IS NOT NULL OR row.protein_g IS NOT NULL OR row.fat_g IS NOT NULL OR row.carbs_g IS NOT NULL),
    row.is_estimate, row.ai_provider, row.ai_model, row.created_at;
END;
$$;

COMMENT ON FUNCTION public.record_food_entry(text, text, uuid, uuid, numeric, numeric, numeric, numeric, text, text, jsonb) IS
  'Saves a food entry for the caller (user_id is always auth.uid()). If p_group_id is given the caller must already be a member of that group. Macro fields are coalesced to 0 with a has_macros flag in the return row -- never a raw NULL. Errors: KITPAT_UNAUTHENTICATED / KITPAT_DESCRIPTION_REQUIRED / KITPAT_NOT_GROUP_MEMBER.';

REVOKE ALL ON FUNCTION public.record_food_entry(text, text, uuid, uuid, numeric, numeric, numeric, numeric, text, text, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_food_entry(text, text, uuid, uuid, numeric, numeric, numeric, numeric, text, text, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.record_food_entry(text, text, uuid, uuid, numeric, numeric, numeric, numeric, text, text, jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- list_food_entries -- p_group_id NULL: the caller's own personal entries
-- (group_id IS NULL, user_id = caller). p_group_id set: every entry shared
-- to that group by ANY member (the group's shared feed) -- caller must be
-- a member.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_food_entries(
  p_group_id uuid DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
) RETURNS TABLE (
  id uuid,
  user_id uuid,
  user_name text,
  group_id uuid,
  media_id uuid,
  description text,
  serving text,
  calories_kcal numeric,
  protein_g numeric,
  fat_g numeric,
  carbs_g numeric,
  has_macros boolean,
  is_estimate boolean,
  ai_provider text,
  ai_model text,
  created_at timestamptz
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
  IF p_group_id IS NOT NULL AND NOT public.is_group_member(p_group_id, uid) THEN
    RAISE EXCEPTION 'KITPAT_NOT_GROUP_MEMBER' USING ERRCODE = 'PT403';
  END IF;

  RETURN QUERY
  SELECT
    f.id, f.user_id, u.name, f.group_id, f.media_id, f.description, f.serving,
    coalesce(f.calories_kcal, 0), coalesce(f.protein_g, 0), coalesce(f.fat_g, 0), coalesce(f.carbs_g, 0),
    (f.calories_kcal IS NOT NULL OR f.protein_g IS NOT NULL OR f.fat_g IS NOT NULL OR f.carbs_g IS NOT NULL),
    f.is_estimate, f.ai_provider, f.ai_model, f.created_at
  FROM public.food_entries f
  LEFT JOIN public.users u ON u.id = f.user_id
  WHERE
    (p_group_id IS NULL AND f.group_id IS NULL AND f.user_id = uid)
    OR (p_group_id IS NOT NULL AND f.group_id = p_group_id)
  ORDER BY f.created_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.list_food_entries(uuid, int, int) IS
  'p_group_id NULL: the caller''s own personal entries. p_group_id set: that group''s shared feed (every member''s shared entries) -- caller must be a member. Macro fields coalesced to 0 with a has_macros flag -- never a raw NULL. Errors: KITPAT_UNAUTHENTICATED / KITPAT_NOT_GROUP_MEMBER.';

REVOKE ALL ON FUNCTION public.list_food_entries(uuid, int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.list_food_entries(uuid, int, int) FROM anon;
GRANT EXECUTE ON FUNCTION public.list_food_entries(uuid, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- delete_food_entry -- owner only. KITPAT_NOT_FOUND covers both "does not
-- exist" and "exists but isn't yours" (indistinguishable to the caller).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_food_entry(p_entry_id uuid)
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

  DELETE FROM public.food_entries
  WHERE id = p_entry_id AND user_id = uid
  RETURNING id INTO deleted_id;

  IF deleted_id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
END;
$$;

COMMENT ON FUNCTION public.delete_food_entry(uuid) IS
  'Owner-only delete. KITPAT_NOT_FOUND whether the entry does not exist or simply is not the caller''s. Errors: KITPAT_UNAUTHENTICATED / KITPAT_NOT_FOUND.';

REVOKE ALL ON FUNCTION public.delete_food_entry(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.delete_food_entry(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_food_entry(uuid) TO authenticated, service_role;
