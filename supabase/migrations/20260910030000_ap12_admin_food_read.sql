-- ---------------------------------------------------------------------------
-- AP12: admin read path for food tracking (P41/P41.1/P42), which landed
-- with none. Follows the AP7 pattern exactly: SECURITY DEFINER,
-- is_admin()-gated, KITPAT_* codes, GRANT to authenticated + service_role,
-- REVOKE EXECUTE FROM anon (AP8 lesson: REVOKE ALL FROM PUBLIC alone does
-- not remove Supabase's default anon grant).
--
-- Column lists below were read directly from
-- 20260909040000_p41_food_tracking.sql (food_entries),
-- 20260909040000_p41_food_tracking.sql + 20260910010000_p42_food_cache_and_
-- image.sql (ai_usage_log: base columns from P41.1's section of the P41
-- migration, input_kind added by P42), and
-- 20260910010000_p42_food_cache_and_image.sql (food_cache) -- not assumed.
--
-- Read-only except for one deliberate exception: admin_delete_food_cache_
-- entry. No editing or deleting of a member's own food_entries is added --
-- that stays the member's own data, via their existing delete_food_entry.
-- No existing RLS policy, table, or function is changed.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. admin_list_food_entries -- p_search matches description.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_food_entries(
  p_search text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_group_id uuid DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
) RETURNS TABLE (
  id uuid,
  member_name text,
  group_name text,
  description text,
  serving text,
  calories_kcal numeric,
  protein_g numeric,
  fat_g numeric,
  carbs_g numeric,
  ai_provider text,
  ai_model text,
  is_estimate boolean,
  created_at timestamptz
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
  SELECT
    f.id, u.name, g.name,
    f.description, f.serving, f.calories_kcal, f.protein_g, f.fat_g, f.carbs_g,
    f.ai_provider, f.ai_model, f.is_estimate, f.created_at
  FROM public.food_entries f
  LEFT JOIN public.users u ON u.id = f.user_id
  LEFT JOIN public.groups g ON g.id = f.group_id
  WHERE (p_search IS NULL OR f.description ILIKE '%' || p_search || '%')
    AND (p_user_id IS NULL OR f.user_id = p_user_id)
    AND (p_group_id IS NULL OR f.group_id = p_group_id)
  ORDER BY f.created_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.admin_list_food_entries(text, uuid, uuid, int, int) IS
  'Any active admin. Every food_entries row (optionally filtered by description search, user, or group), with member/group names resolved -- group_name is NULL for a personal (unshared) entry. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_food_entries(text, uuid, uuid, int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_list_food_entries(text, uuid, uuid, int, int) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_food_entries(text, uuid, uuid, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. admin_food_entry_detail -- same shape plus ai_raw. The provider's
--    full raw response is useful for debugging a bad estimate and carries
--    no payment or identity data -- safe for an admin, no reveal/audit
--    treatment needed (unlike a phone number).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_food_entry_detail(p_entry_id uuid)
RETURNS TABLE (
  id uuid,
  member_name text,
  group_name text,
  description text,
  serving text,
  calories_kcal numeric,
  protein_g numeric,
  fat_g numeric,
  carbs_g numeric,
  ai_provider text,
  ai_model text,
  is_estimate boolean,
  created_at timestamptz,
  ai_raw jsonb
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

  IF NOT EXISTS (SELECT 1 FROM public.food_entries f WHERE f.id = p_entry_id) THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  RETURN QUERY
  SELECT
    f.id, u.name, g.name,
    f.description, f.serving, f.calories_kcal, f.protein_g, f.fat_g, f.carbs_g,
    f.ai_provider, f.ai_model, f.is_estimate, f.created_at, f.ai_raw
  FROM public.food_entries f
  LEFT JOIN public.users u ON u.id = f.user_id
  LEFT JOIN public.groups g ON g.id = f.group_id
  WHERE f.id = p_entry_id;
END;
$$;

COMMENT ON FUNCTION public.admin_food_entry_detail(uuid) IS
  'Any active admin. admin_list_food_entries'' shape for one entry, plus ai_raw (the provider''s full raw response -- no payment or identity data). Errors: KITPAT_ADMIN_ONLY / KITPAT_NOT_FOUND.';

REVOKE ALL ON FUNCTION public.admin_food_entry_detail(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_food_entry_detail(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_food_entry_detail(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. admin_ai_usage_summary -- the spend view: per-member, per-day rollup
--    of ai_usage_log, so image-vs-text spend is visible (an image call
--    costs roughly 10x a text call in input tokens, per P42).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_ai_usage_summary(p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS TABLE (
  usage_date date,
  user_id uuid,
  member_name text,
  feature text,
  provider text,
  model text,
  input_kind text,
  succeeded_count bigint,
  failed_count bigint
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
  SELECT
    (a.created_at AT TIME ZONE 'UTC')::date AS usage_date,
    a.user_id,
    u.name,
    a.feature,
    a.provider,
    a.model,
    a.input_kind,
    count(*) FILTER (WHERE a.succeeded) AS succeeded_count,
    count(*) FILTER (WHERE NOT a.succeeded) AS failed_count
  FROM public.ai_usage_log a
  LEFT JOIN public.users u ON u.id = a.user_id
  WHERE (p_from IS NULL OR (a.created_at AT TIME ZONE 'UTC')::date >= p_from)
    AND (p_to IS NULL OR (a.created_at AT TIME ZONE 'UTC')::date <= p_to)
  GROUP BY usage_date, a.user_id, u.name, a.feature, a.provider, a.model, a.input_kind
  ORDER BY usage_date DESC, u.name;
END;
$$;

COMMENT ON FUNCTION public.admin_ai_usage_summary(date, date) IS
  'Any active admin. Per-member, per-UTC-day rollup of ai_usage_log (optionally date-bounded): feature/provider/model/input_kind with counts of succeeded and failed calls. The spend view -- shows whether image lookups are burning budget. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_ai_usage_summary(date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_ai_usage_summary(date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_ai_usage_summary(date, date) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. admin_list_food_cache -- id is included even though not named in the
--    task's column list, since admin_delete_food_cache_entry below needs
--    something to target and normalized_key (while unique) is an awkward
--    row identifier for a delete action; id is the natural one.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_food_cache(
  p_search text DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
) RETURNS TABLE (
  id uuid,
  normalized_key text,
  sample_description text,
  serving text,
  calories_kcal numeric,
  protein_g numeric,
  fat_g numeric,
  carbs_g numeric,
  ai_provider text,
  ai_model text,
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
  SELECT
    c.id, c.normalized_key, c.sample_description, c.serving,
    c.calories_kcal, c.protein_g, c.fat_g, c.carbs_g,
    c.ai_provider, c.ai_model, c.hit_count, c.created_at, c.last_hit_at
  FROM public.food_cache c
  WHERE (p_search IS NULL OR c.normalized_key ILIKE '%' || p_search || '%' OR c.sample_description ILIKE '%' || p_search || '%')
  ORDER BY c.hit_count DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.admin_list_food_cache(text, int, int) IS
  'Any active admin. Every food_cache row (optionally filtered by key/description search), ordered by hit_count descending. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_food_cache(text, int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_list_food_cache(text, int, int) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_food_cache(text, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. admin_delete_food_cache_entry -- the ONE write in this migration.
--    Owner/org_admin only, audited via log_admin_action. Deleting a cache
--    row is safe (the next lookup simply re-queries the provider); a
--    wrong cached entry, left in place, is served to every member who
--    types that dish.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_delete_food_cache_entry(p_cache_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_admin_id uuid;
  caller_email text;
  before_row jsonb;
  deleted_id uuid;
BEGIN
  IF NOT public.is_admin() OR public.admin_role() NOT IN ('owner', 'org_admin') THEN
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
  END IF;

  SELECT to_jsonb(c) INTO before_row FROM public.food_cache c WHERE c.id = p_cache_id;
  IF before_row IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  caller_email := auth.jwt() ->> 'email';
  SELECT id INTO caller_admin_id FROM public.admins WHERE email = caller_email AND is_active = true;

  DELETE FROM public.food_cache WHERE id = p_cache_id RETURNING id INTO deleted_id;
  IF deleted_id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  -- Called directly with the admin's own JWT (role=authenticated, not
  -- service_role) -- the AP7.2 guard on log_admin_action accepts this via
  -- is_admin() (already checked above) and, since this is not a
  -- service_role caller, ignores the actor override below and
  -- self-derives the same caller_email/caller_admin_id anyway.
  PERFORM public.log_admin_action(
    'delete:food_cache', 'food_cache', p_cache_id::text,
    before_row, NULL, false, NULL, NULL, caller_admin_id, caller_email
  );
END;
$$;

COMMENT ON FUNCTION public.admin_delete_food_cache_entry(uuid) IS
  'Owner/org_admin only (member admins rejected). Deletes one food_cache row and audits it via log_admin_action(''delete:food_cache'', ...). The next matching lookup simply re-queries the provider and re-populates the cache. Errors: KITPAT_INSUFFICIENT_ROLE / KITPAT_NOT_FOUND.';

REVOKE ALL ON FUNCTION public.admin_delete_food_cache_entry(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_food_cache_entry(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_food_cache_entry(uuid) TO authenticated, service_role;
