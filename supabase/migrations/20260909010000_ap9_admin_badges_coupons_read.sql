-- ---------------------------------------------------------------------------
-- AP9: unblock two admin tabs that fail today because the backend does not
-- support them -- badges (missing is_active/sort_order) and coupons
-- (readable by nothing at all, not even an admin).
--
-- Both write paths already exist and are NOT reinvented here:
--   - badge_definitions has been in admin_can_write's allow-list and
--     admin-write's PK_COLUMN map since AP1 (org_admin + owner writable,
--     audited via log_admin_action). Adding is_active/sort_order as plain
--     columns is enough -- the existing insert/update path already
--     accepts an arbitrary payload for any allow-listed table, so once
--     the columns exist the admin frontend can set them through the same
--     admin-write call it already makes for every other badge edit.
--   - coupons/coupon_targets have been in that same allow-list since AP4
--     (owner-only). Coupon create/edit already goes through admin-write;
--     only the READ side is missing, which is what this migration adds.
-- No new edge function, no new admin_can_write entry, no change to
-- admin-write/index.ts.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. badge_definitions: is_active + sort_order.
--
-- ADD COLUMN ... DEFAULT true backfills every existing row to true as part
-- of the same statement (Postgres fills existing rows with the column
-- default when adding a NOT NULL column with one) -- no separate UPDATE
-- needed, and no row disappears from the member app. Additive only:
-- nothing dropped, nothing renamed.
--
-- The existing badges_public_read policy (`USING (true)`, no role
-- restriction) is untouched -- it does not filter on is_active, so it
-- keeps working exactly as before for the member app. (If the member app
-- is later changed to only show active badges, that is a member-facing
-- RLS/query change out of scope here -- this migration only adds the
-- column the admin tab needs to exist.)
-- ---------------------------------------------------------------------------
ALTER TABLE public.badge_definitions
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS sort_order integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.badge_definitions.is_active IS
  'Admin-editable via the existing AP1 admin-write path (badge_definitions has been allow-listed, org_admin+owner, since AP1). Defaults true so every pre-existing badge stays visible; badges_public_read is unfiltered by this column, so a false row is still member-readable until/unless a separate frontend change is made to filter on it.';
COMMENT ON COLUMN public.badge_definitions.sort_order IS
  'Admin-editable display order, same write path as is_active. Defaults 0.';

-- ---------------------------------------------------------------------------
-- 2. Coupons: admin read RPCs. RLS on coupons/coupon_targets stays exactly
--    as AP4 left it -- RLS enabled, ZERO client policies, no grant to
--    authenticated. No blanket policy is added here. These two
--    SECURITY DEFINER RPCs are the only admin read path, matching AP7's
--    pattern for groups/ledger.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 2a. admin_list_coupons(p_search, p_limit, p_offset)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_coupons(
  p_search text DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
) RETURNS TABLE (
  id uuid,
  code text,
  type text,
  value numeric(12,2),
  currency text,
  applies_to_plan_id uuid,
  razorpay_required boolean,
  max_redemptions integer,
  redemption_count integer,
  starts_at timestamptz,
  expires_at timestamptz,
  is_active boolean,
  notes text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  target_count bigint
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
    c.id, c.code, c.type, c.value, c.currency, c.applies_to_plan_id, c.razorpay_required,
    c.max_redemptions, c.redemption_count, c.starts_at, c.expires_at, c.is_active, c.notes,
    c.created_by, c.created_at, c.updated_at,
    (SELECT count(*) FROM public.coupon_targets t WHERE t.coupon_id = c.id) AS target_count
  FROM public.coupons c
  WHERE p_search IS NULL OR c.code ILIKE '%' || p_search || '%'
  ORDER BY c.created_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.admin_list_coupons(text, int, int) IS
  'Any active admin. Every coupon (optionally code-filtered) plus target_count. coupons has zero client SELECT policy by design (AP4) -- this RPC is the only admin read path. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_coupons(text, int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_list_coupons(text, int, int) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_coupons(text, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2b. admin_coupon_detail(p_coupon_id) -- the coupon plus its targets and
--     redemption history. Targets are the admin's own input (phone/email/
--     user_id an admin chose when creating the coupon), returned as-is.
--     Redemption rows join to a MASKED user identity (name + masked
--     phone, same +91X...NN rule as AP2/AP7) -- never a raw phone/email
--     pulled from a user's own account record.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_coupon_detail(p_coupon_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  c public.coupons;
  result jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  SELECT * INTO c FROM public.coupons WHERE id = p_coupon_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  SELECT jsonb_build_object(
    'id', c.id,
    'code', c.code,
    'type', c.type,
    'value', c.value,
    'currency', c.currency,
    'applies_to_plan_id', c.applies_to_plan_id,
    'razorpay_required', c.razorpay_required,
    'max_redemptions', c.max_redemptions,
    'redemption_count', c.redemption_count,
    'starts_at', c.starts_at,
    'expires_at', c.expires_at,
    'is_active', c.is_active,
    'notes', c.notes,
    'created_by', c.created_by,
    'created_at', c.created_at,
    'updated_at', c.updated_at,
    'targets', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', t.id,
          'phone', t.phone,
          'email', t.email,
          'user_id', t.user_id,
          'created_at', t.created_at
        )
        ORDER BY t.created_at
      )
      FROM public.coupon_targets t
      WHERE t.coupon_id = c.id
    ), '[]'::jsonb),
    'redemptions', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', r.id,
          'user_id', r.user_id,
          'user_name', u.name,
          'masked_phone', CASE WHEN u.phone IS NULL THEN NULL
            ELSE '+91' || repeat('X', greatest(length(u.phone) - 2, 0)) || right(u.phone, 2)
          END,
          'redeemed_at', r.redeemed_at,
          'subscription_id', r.subscription_id,
          'notes', r.notes
        )
        ORDER BY r.redeemed_at DESC
      )
      FROM public.coupon_redemptions r
      LEFT JOIN public.users u ON u.id = r.user_id
      WHERE r.coupon_id = c.id
    ), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$$;

COMMENT ON FUNCTION public.admin_coupon_detail(uuid) IS
  'Any active admin. One coupon plus its coupon_targets (admin-authored, returned as-is) and coupon_redemptions history (masked user identity -- name + masked phone, never raw). Errors: KITPAT_ADMIN_ONLY / KITPAT_NOT_FOUND.';

REVOKE ALL ON FUNCTION public.admin_coupon_detail(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_coupon_detail(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_coupon_detail(uuid) TO authenticated, service_role;
