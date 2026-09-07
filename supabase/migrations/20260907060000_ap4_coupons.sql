-- ---------------------------------------------------------------------------
-- AP4: admin-created, trackable, optionally per-user-targeted coupons.
--
-- Billing rule agreed with the product owner:
--   'percent' / 'flat'          -- discount a real charge, go through
--                                  Razorpay (razorpay_required = true)
--   'free_months' / 'free'      -- grant entitlement directly, NO Razorpay
--                                  involvement (razorpay_required = false)
--
-- razorpay_required is a GENERATED ALWAYS ... STORED column derived from
-- type, so it can never drift from it (and can't be set independently on
-- INSERT/UPDATE -- Postgres rejects any attempt to do so).
--
-- coupons/coupon_targets are admin-only data: RLS enables row security with
-- deliberately zero policies (service_role only, mirroring
-- admin_reveal_requests from AP2). Redemption happens through
-- validate_coupon/redeem_coupon, not by reading the table directly.
--
-- coupon_redemptions is the one user-facing table here: a user may read
-- their own redemption rows; no client writes (redeem_coupon, SECURITY
-- DEFINER, is the only writer).
--
-- Coupon writes go through the AP1 admin-write path, OWNER-ONLY (like
-- plans) -- added to admin_can_write below, and to the admin-write edge
-- function's allow-list in the same PR (not this migration).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. coupons
-- ---------------------------------------------------------------------------
CREATE TABLE public.coupons (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text UNIQUE NOT NULL,
  type text NOT NULL CHECK (type IN ('percent', 'flat', 'free_months', 'free')),
  value numeric(12,2),
  currency text DEFAULT 'INR',
  applies_to_plan_id uuid REFERENCES public.plans(id),
  max_redemptions integer,
  redemption_count integer NOT NULL DEFAULT 0,
  starts_at timestamptz,
  expires_at timestamptz,
  is_active boolean NOT NULL DEFAULT true,
  notes text,
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  razorpay_required boolean GENERATED ALWAYS AS (type IN ('percent', 'flat')) STORED,
  CONSTRAINT coupons_value_positive_check CHECK (
    type = 'free' OR (value IS NOT NULL AND value > 0)
  ),
  CONSTRAINT coupons_percent_max_check CHECK (
    type <> 'percent' OR value <= 100
  )
);

COMMENT ON TABLE public.coupons IS
  'Admin-created coupons. razorpay_required is GENERATED ALWAYS from type (percent/flat = true, free_months/free = false) so it can never drift. Admin-only data: RLS has zero client policies (service_role only); redemption is via validate_coupon/redeem_coupon, never a direct client SELECT.';

ALTER TABLE public.coupons ENABLE ROW LEVEL SECURITY;
-- Deliberately zero policies: RLS default-denies every command for every
-- role that isn't exempt. service_role is exempt (its own role attribute)
-- and holds explicit grants below; anon/authenticated get nothing at all.

REVOKE ALL ON public.coupons FROM anon;
REVOKE ALL ON public.coupons FROM authenticated;
GRANT ALL ON public.coupons TO service_role;

CREATE TRIGGER coupons_updated_at
  BEFORE UPDATE ON public.coupons
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ---------------------------------------------------------------------------
-- 2. coupon_targets -- optional per-user targeting. A coupon with zero
--    target rows is untargeted (eligible for any user).
-- ---------------------------------------------------------------------------
CREATE TABLE public.coupon_targets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coupon_id uuid NOT NULL REFERENCES public.coupons(id) ON DELETE CASCADE,
  phone text,
  email text,
  user_id uuid REFERENCES public.users(id),
  created_at timestamptz DEFAULT now(),
  CONSTRAINT coupon_targets_target_required_check CHECK (
    phone IS NOT NULL OR email IS NOT NULL OR user_id IS NOT NULL
  )
);

COMMENT ON TABLE public.coupon_targets IS
  'Optional per-user targeting for a coupon (matched on user_id, phone, or email by validate_coupon/redeem_coupon). A coupon with no target rows is eligible for any user. Admin-only data: RLS has zero client policies (service_role only).';

ALTER TABLE public.coupon_targets ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.coupon_targets FROM anon;
REVOKE ALL ON public.coupon_targets FROM authenticated;
GRANT ALL ON public.coupon_targets TO service_role;

-- ---------------------------------------------------------------------------
-- 3. coupon_redemptions -- one row per (coupon, user); a user may read
--    their own rows, no client writes (redeem_coupon is the only writer).
-- ---------------------------------------------------------------------------
CREATE TABLE public.coupon_redemptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coupon_id uuid NOT NULL REFERENCES public.coupons(id),
  user_id uuid NOT NULL REFERENCES public.users(id),
  redeemed_at timestamptz DEFAULT now(),
  subscription_id uuid,
  notes text,
  UNIQUE (coupon_id, user_id)
);

COMMENT ON TABLE public.coupon_redemptions IS
  'One row per successful coupon redemption (coupon_id, user_id) unique -- a coupon may be redeemed once per user. Written only by redeem_coupon (SECURITY DEFINER). RLS: a user may SELECT their own rows; no client writes.';

ALTER TABLE public.coupon_redemptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users read own coupon redemptions" ON public.coupon_redemptions;
CREATE POLICY "users read own coupon redemptions"
  ON public.coupon_redemptions FOR SELECT TO authenticated
  USING (user_id = auth.uid());

REVOKE ALL ON public.coupon_redemptions FROM anon;
GRANT SELECT ON public.coupon_redemptions TO authenticated;
GRANT ALL ON public.coupon_redemptions TO service_role;

-- ---------------------------------------------------------------------------
-- 4. validate_coupon(p_code) -- read-only check for the calling user.
--    Never raises for an ordinary ineligibility reason (unknown code,
--    inactive, not started, expired, exhausted, already redeemed, not
--    targeted) -- returns valid=false + a stable reason instead, so the
--    frontend can show a message without a round-trip error. The
--    not-targeted case deliberately returns the SAME reason as an unknown
--    code (KITPAT_COUPON_INVALID), so a user who isn't targeted can never
--    tell a real code from a made-up one.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_coupon(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_id uuid;
  caller_phone text;
  caller_email text;
  c public.coupons;
  has_targets boolean;
  is_targeted boolean;
  already_redeemed boolean;
BEGIN
  caller_id := auth.uid();
  IF caller_id IS NULL THEN
    RETURN jsonb_build_object('valid', false, 'code', p_code, 'reason', 'KITPAT_UNAUTHENTICATED');
  END IF;

  SELECT phone, email INTO caller_phone, caller_email FROM public.users WHERE id = caller_id;

  SELECT * INTO c FROM public.coupons WHERE code = p_code;
  IF c.id IS NULL OR NOT c.is_active OR (c.starts_at IS NOT NULL AND c.starts_at > now()) THEN
    RETURN jsonb_build_object('valid', false, 'code', p_code, 'reason', 'KITPAT_COUPON_INVALID');
  END IF;

  IF c.expires_at IS NOT NULL AND c.expires_at < now() THEN
    RETURN jsonb_build_object('valid', false, 'code', p_code, 'reason', 'KITPAT_COUPON_EXPIRED');
  END IF;

  IF c.max_redemptions IS NOT NULL AND c.redemption_count >= c.max_redemptions THEN
    RETURN jsonb_build_object('valid', false, 'code', p_code, 'reason', 'KITPAT_COUPON_EXHAUSTED');
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.coupon_redemptions WHERE coupon_id = c.id AND user_id = caller_id
  ) INTO already_redeemed;
  IF already_redeemed THEN
    RETURN jsonb_build_object('valid', false, 'code', p_code, 'reason', 'KITPAT_COUPON_ALREADY_REDEEMED');
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.coupon_targets WHERE coupon_id = c.id) INTO has_targets;
  IF has_targets THEN
    SELECT EXISTS(
      SELECT 1 FROM public.coupon_targets t
      WHERE t.coupon_id = c.id
        AND (
          t.user_id = caller_id
          OR (t.phone IS NOT NULL AND t.phone = caller_phone)
          OR (t.email IS NOT NULL AND t.email = caller_email)
        )
    ) INTO is_targeted;
    IF NOT is_targeted THEN
      -- Never leak whether the code exists to a user it isn't targeted at:
      -- same reason as "unknown code".
      RETURN jsonb_build_object('valid', false, 'code', p_code, 'reason', 'KITPAT_COUPON_INVALID');
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'valid', true,
    'code', c.code,
    'type', c.type,
    'value', c.value,
    'razorpay_required', c.razorpay_required,
    'applies_to_plan_id', c.applies_to_plan_id,
    'reason', NULL
  );
END;
$$;

COMMENT ON FUNCTION public.validate_coupon(text) IS
  'For the calling user (auth.uid()): {valid, code, type, value, razorpay_required, applies_to_plan_id, reason}. Never raises for an ordinary ineligibility reason -- returns valid=false + a stable KITPAT_* reason (KITPAT_COUPON_INVALID for unknown/inactive/not-started/not-targeted -- deliberately indistinguishable from each other -- or KITPAT_COUPON_EXPIRED / KITPAT_COUPON_EXHAUSTED / KITPAT_COUPON_ALREADY_REDEEMED).';

REVOKE ALL ON FUNCTION public.validate_coupon(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_coupon(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. redeem_coupon(p_code, p_subscription_id) -- re-runs the same
--    validation atomically under a row lock on the coupon (FOR UPDATE), so
--    two concurrent redemptions of a near-exhausted coupon can't both
--    succeed, then inserts the redemption and increments redemption_count
--    in the same transaction. Unlike validate_coupon, an ineligible
--    targeted coupon DOES get its own distinct code here
--    (KITPAT_COUPON_NOT_ELIGIBLE) -- this is an authenticated user actively
--    attempting a specific code, not a passive check, so there is nothing
--    left to avoid leaking.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.redeem_coupon(p_code text, p_subscription_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_id uuid;
  caller_phone text;
  caller_email text;
  c public.coupons;
  has_targets boolean;
  is_targeted boolean;
  already_redeemed boolean;
BEGIN
  caller_id := auth.uid();
  IF caller_id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;

  SELECT phone, email INTO caller_phone, caller_email FROM public.users WHERE id = caller_id;

  SELECT * INTO c FROM public.coupons WHERE code = p_code FOR UPDATE;
  IF c.id IS NULL OR NOT c.is_active OR (c.starts_at IS NOT NULL AND c.starts_at > now()) THEN
    RAISE EXCEPTION 'KITPAT_COUPON_INVALID' USING ERRCODE = 'PT404';
  END IF;

  IF c.expires_at IS NOT NULL AND c.expires_at < now() THEN
    RAISE EXCEPTION 'KITPAT_COUPON_EXPIRED' USING ERRCODE = 'PT409';
  END IF;

  IF c.max_redemptions IS NOT NULL AND c.redemption_count >= c.max_redemptions THEN
    RAISE EXCEPTION 'KITPAT_COUPON_EXHAUSTED' USING ERRCODE = 'PT409';
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.coupon_redemptions WHERE coupon_id = c.id AND user_id = caller_id
  ) INTO already_redeemed;
  IF already_redeemed THEN
    RAISE EXCEPTION 'KITPAT_COUPON_ALREADY_REDEEMED' USING ERRCODE = 'PT409';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.coupon_targets WHERE coupon_id = c.id) INTO has_targets;
  IF has_targets THEN
    SELECT EXISTS(
      SELECT 1 FROM public.coupon_targets t
      WHERE t.coupon_id = c.id
        AND (
          t.user_id = caller_id
          OR (t.phone IS NOT NULL AND t.phone = caller_phone)
          OR (t.email IS NOT NULL AND t.email = caller_email)
        )
    ) INTO is_targeted;
    IF NOT is_targeted THEN
      RAISE EXCEPTION 'KITPAT_COUPON_NOT_ELIGIBLE' USING ERRCODE = 'PT403';
    END IF;
  END IF;

  INSERT INTO public.coupon_redemptions (coupon_id, user_id, subscription_id)
  VALUES (c.id, caller_id, p_subscription_id);

  UPDATE public.coupons SET redemption_count = redemption_count + 1 WHERE id = c.id;

  -- For 'free_months'/'free' this is the whole story -- no Razorpay call.
  -- For 'percent'/'flat' this only records the redemption; the actual
  -- discounted charge is Razorpay's job and is out of scope here.
  RETURN jsonb_build_object(
    'redeemed', true,
    'code', c.code,
    'type', c.type,
    'value', c.value,
    'razorpay_required', c.razorpay_required,
    'applies_to_plan_id', c.applies_to_plan_id
  );
END;
$$;

COMMENT ON FUNCTION public.redeem_coupon(text, uuid) IS
  'For the calling user (auth.uid()): re-validates p_code under a row lock on the coupon, then atomically inserts a coupon_redemptions row and increments redemption_count. Errors: KITPAT_UNAUTHENTICATED / KITPAT_COUPON_INVALID (404) / KITPAT_COUPON_EXPIRED (409) / KITPAT_COUPON_EXHAUSTED (409) / KITPAT_COUPON_ALREADY_REDEEMED (409) / KITPAT_COUPON_NOT_ELIGIBLE (403). For percent/flat coupons the actual discounted Razorpay charge is out of scope here -- only the redemption is recorded.';

REVOKE ALL ON FUNCTION public.redeem_coupon(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.redeem_coupon(text, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. admin_can_write -- add coupons/coupon_targets, OWNER-ONLY like plans.
--    Recreated in full (not additive) since this is the single source of
--    truth for the complete allow-listed table set; CREATE OR REPLACE
--    keeps the same signature/grants as AP1 and AP3.1's versions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_can_write(p_table text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT
    public.is_admin()
    AND p_table = ANY (ARRAY[
      'badge_definitions', 'invite_templates', 'plans', 'game_theme_packs',
      'festival_themes', 'greeting_variants', 'tambola_variants',
      'festival_cards', 'promo_cards', 'coupons', 'coupon_targets'
    ])
    AND (
      public.admin_role() = 'owner'
      OR (public.admin_role() = 'org_admin' AND p_table NOT IN ('plans', 'coupons', 'coupon_targets'))
    );
$$;

COMMENT ON FUNCTION public.admin_can_write(text) IS
  'True if the caller is an active admin whose role permits writing p_table: owner writes every allow-listed table, org_admin writes all except the owner-only set (plans, coupons, coupon_targets), member never writes. The one place this rule is defined -- the admin-write edge function re-checks it as defense in depth.';

REVOKE ALL ON FUNCTION public.admin_can_write(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_can_write(text) TO authenticated, service_role;
