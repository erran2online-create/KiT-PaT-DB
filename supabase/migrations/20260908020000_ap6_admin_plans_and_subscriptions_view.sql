-- ---------------------------------------------------------------------------
-- AP6: a safe, audited view and edit path for plans and subscriptions --
-- and a guard so a plan edit can never silently break live subscribers.
--
-- Plan writes still go through admin-write with service_role and audit
-- logging (AP1); admin_can_write's plans = owner-only rule is untouched.
-- This migration adds read-side RPCs (so an owner can see impact BEFORE
-- editing) and a data-integrity trigger (so the one genuinely dangerous
-- plan edit -- renaming a slug live subscribers reference -- is blocked
-- at the table level, regardless of which role or path performs the
-- UPDATE).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. admin_list_plans() -- every plan plus its active_subscriber_count.
--    What the admin Plans tab reads.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_plans()
RETURNS TABLE (
  id uuid,
  name text,
  slug text,
  price_monthly integer,
  price_yearly integer,
  price_yearly_per_month integer,
  currency text,
  is_active boolean,
  is_popular boolean,
  razorpay_plan_id_monthly text,
  razorpay_plan_id_yearly text,
  features jsonb,
  limits jsonb,
  name_neutral text,
  name_variant_female text,
  name_variant_male text,
  created_at timestamptz,
  active_subscriber_count bigint
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
    p.id, p.name, p.slug, p.price_monthly, p.price_yearly, p.price_yearly_per_month,
    p.currency, p.is_active, p.is_popular, p.razorpay_plan_id_monthly, p.razorpay_plan_id_yearly,
    p.features, p.limits, p.name_neutral, p.name_variant_female, p.name_variant_male, p.created_at,
    coalesce(s.active_count, 0) AS active_subscriber_count
  FROM public.plans p
  LEFT JOIN (
    SELECT plan_id, count(*) AS active_count
    FROM public.subscriptions
    WHERE status = 'active'
    GROUP BY plan_id
  ) s ON s.plan_id = p.id
  ORDER BY p.created_at;
END;
$$;

COMMENT ON FUNCTION public.admin_list_plans() IS
  'Any active admin. Every plans row plus active_subscriber_count (count of subscriptions.status = ''active'' on that plan) -- lets an owner see how many people a change would affect before editing. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_plans() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_plans() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. admin_plan_change_impact(p_plan_id, p_new_limits) -- report-only,
--    changes nothing. reduced_keys is the dangerous direction: a limit
--    being LOWERED, since existing subscribers may already exceed the new
--    ceiling.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_plan_change_impact(p_plan_id uuid, p_new_limits jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  current_limits jsonb;
  reduced jsonb := '{}'::jsonb;
  added jsonb := '{}'::jsonb;
  k text;
  old_val jsonb;
  new_val jsonb;
  active_subs integer;
BEGIN
  IF NOT public.is_admin_owner() THEN
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
  END IF;

  SELECT limits INTO current_limits FROM public.plans WHERE id = p_plan_id;
  IF current_limits IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  FOR k, new_val IN SELECT key, value FROM jsonb_each(coalesce(p_new_limits, '{}'::jsonb)) LOOP
    old_val := current_limits -> k;
    IF old_val IS NULL THEN
      added := added || jsonb_build_object(k, new_val);
    ELSIF jsonb_typeof(old_val) = 'number' AND jsonb_typeof(new_val) = 'number'
      AND (new_val)::text::numeric < (old_val)::text::numeric THEN
      reduced := reduced || jsonb_build_object(k, jsonb_build_object('old', old_val, 'new', new_val));
    END IF;
  END LOOP;

  SELECT count(*) INTO active_subs FROM public.subscriptions WHERE plan_id = p_plan_id AND status = 'active';

  RETURN jsonb_build_object(
    'plan_id', p_plan_id,
    'active_subscribers', active_subs,
    'reduced_keys', reduced,
    'added_keys', added,
    'warning', (reduced <> '{}'::jsonb AND active_subs > 0)
  );
END;
$$;

COMMENT ON FUNCTION public.admin_plan_change_impact(uuid, jsonb) IS
  'Owner-only. Compares p_new_limits against plan_id''s current limits: reduced_keys lists every key being lowered (old/new pair, the dangerous direction), added_keys lists new keys not present before. warning = reduced_keys non-empty AND active_subscribers > 0. Report-only -- changes nothing. Errors: KITPAT_INSUFFICIENT_ROLE / KITPAT_NOT_FOUND.';

REVOKE ALL ON FUNCTION public.admin_plan_change_impact(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_plan_change_impact(uuid, jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Guard rail: block a slug change on a plan with any active
--    subscription. Table-level trigger, so it applies regardless of which
--    role or path performs the UPDATE (including admin-write's
--    service_role client) -- price, features, limits, display names and
--    razorpay ids all remain freely editable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.plans_guard_slug_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  active_subs integer;
BEGIN
  IF NEW.slug IS DISTINCT FROM OLD.slug THEN
    SELECT count(*) INTO active_subs FROM public.subscriptions WHERE plan_id = OLD.id AND status = 'active';
    IF active_subs > 0 THEN
      RAISE EXCEPTION 'KITPAT_PLAN_SLUG_LOCKED' USING ERRCODE = 'PT409';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.plans_guard_slug_change() IS
  'BEFORE UPDATE trigger on public.plans: raises KITPAT_PLAN_SLUG_LOCKED if slug is changing and the plan has any active subscription. Slugs are referenced by billing and the frontend; renaming one under live subscribers is the one plan edit that genuinely breaks things.';

REVOKE ALL ON FUNCTION public.plans_guard_slug_change() FROM PUBLIC;
GRANT ALL ON FUNCTION public.plans_guard_slug_change() TO service_role;

DROP TRIGGER IF EXISTS plans_guard_slug_change_trigger ON public.plans;
CREATE TRIGGER plans_guard_slug_change_trigger
  BEFORE UPDATE ON public.plans
  FOR EACH ROW EXECUTE FUNCTION public.plans_guard_slug_change();

-- ---------------------------------------------------------------------------
-- 4. admin_list_subscriptions(p_plan_id, p_limit, p_offset) -- subscription
--    rows joined to a MASKED user identity. Never a raw phone/email --
--    revealing contact details stays exclusively in AP2's owner-only
--    double-verified admin-reveal path.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_subscriptions(
  p_plan_id uuid DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
) RETURNS TABLE (
  id uuid,
  user_id uuid,
  user_name text,
  masked_phone text,
  plan_id uuid,
  status text,
  billing_cycle text,
  started_at timestamptz,
  expires_at timestamptz,
  cancelled_at timestamptz,
  auto_renew boolean,
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
    s.id,
    s.user_id,
    u.name,
    CASE WHEN u.phone IS NULL THEN NULL
      ELSE '+91' || repeat('X', greatest(length(u.phone) - 2, 0)) || right(u.phone, 2)
    END,
    s.plan_id,
    s.status,
    s.billing_cycle,
    s.started_at,
    s.expires_at,
    s.cancelled_at,
    s.auto_renew,
    s.created_at
  FROM public.subscriptions s
  LEFT JOIN public.users u ON u.id = s.user_id
  WHERE p_plan_id IS NULL OR s.plan_id = p_plan_id
  ORDER BY s.created_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.admin_list_subscriptions(uuid, int, int) IS
  'Any active admin. Subscription rows (optionally filtered to p_plan_id) joined to a masked user identity: name and masked_phone (same +91X...NN masking as AP2''s admin_list_users) -- never a raw phone/email. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_subscriptions(uuid, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_subscriptions(uuid, int, int) TO authenticated, service_role;
