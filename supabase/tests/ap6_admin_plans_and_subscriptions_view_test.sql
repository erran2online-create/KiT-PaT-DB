-- AP6 test: admin_list_plans, admin_plan_change_impact, the plans slug
-- guard trigger, and admin_list_subscriptions.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0-AP5 and this migration
-- (20260908020000_ap6_admin_plans_and_subscriptions_view.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap6_admin_plans_and_subscriptions_view_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. admin_list_plans raises KITPAT_ADMIN_ONLY for a non-admin and
--      returns every existing plan row (4, per the live-confirmed seed)
--      with a subscriber count for an admin.
--   2. admin_plan_change_impact raises KITPAT_INSUFFICIENT_ROLE for
--      org_admin, and for an owner correctly reports a lowered limit in
--      reduced_keys with warning=true when subscribers exist and
--      warning=false when none do.
--   3. Updating a plan's slug while it has an active subscription raises
--      KITPAT_PLAN_SLUG_LOCKED; updating its price_monthly succeeds.
--   4. admin_list_subscriptions returns a masked phone and never a raw
--      one.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap6.owner.test@kitpat.in';
  org_admin_email text := 'ap6.orgadmin.test@kitpat.in';
  non_admin_email text := 'ap6.notadmin.test@kitpat.in';
  plans_table_count integer;
  admin_list_count integer;
  any_null_subscriber_count integer;
  err text;
  plan_with_subs uuid;
  plan_without_subs uuid;
  user_with_sub uuid;
  impact jsonb;
  row_rec record;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES
    (owner_email, 'owner', true),
    (org_admin_email, 'org_admin', true)
  ON CONFLICT (email) DO UPDATE SET role = EXCLUDED.role, is_active = true;

  --------------------------------------------------- 1. admin_list_plans
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', non_admin_email, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM * FROM public.admin_list_plans();
    RAISE EXCEPTION 'FAIL: admin_list_plans succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_list_plans raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;

  SELECT count(*) INTO plans_table_count FROM public.plans;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO admin_list_count FROM public.admin_list_plans();
  IF admin_list_count <> plans_table_count THEN
    RAISE EXCEPTION 'FAIL: admin_list_plans returned % rows, expected % (every plans row, per the live-confirmed 4)', admin_list_count, plans_table_count;
  END IF;

  SELECT count(*) INTO any_null_subscriber_count FROM public.admin_list_plans() WHERE active_subscriber_count IS NULL;
  IF any_null_subscriber_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % admin_list_plans row(s) have a NULL active_subscriber_count, expected a count (0 or more) for every plan', any_null_subscriber_count;
  END IF;
  RAISE NOTICE 'PASS: admin_list_plans raises KITPAT_ADMIN_ONLY for a non-admin and returns every plan with a subscriber count for an admin';

  ------------------------------------------------------- fixtures for impact/guard
  INSERT INTO public.plans (name, slug, price_monthly, price_yearly, limits)
  VALUES ('AP6 Test Plan (subs)', 'ap6-test-plan-subs-' || substr(gen_random_uuid()::text, 1, 8), 199, 1999, '{"max_groups": 10, "max_events": 20}'::jsonb)
  RETURNING id INTO plan_with_subs;

  INSERT INTO public.plans (name, slug, price_monthly, price_yearly, limits)
  VALUES ('AP6 Test Plan (no subs)', 'ap6-test-plan-nosubs-' || substr(gen_random_uuid()::text, 1, 8), 199, 1999, '{"max_groups": 10, "max_events": 20}'::jsonb)
  RETURNING id INTO plan_without_subs;

  INSERT INTO public.users (name, phone, city) VALUES ('AP6 Subscriber', '9123456780', 'Delhi') RETURNING id INTO user_with_sub;

  INSERT INTO public.subscriptions (user_id, plan_id, status, billing_cycle)
  VALUES (user_with_sub, plan_with_subs, 'active', 'monthly');

  --------------------------------------------------- 2a. org_admin blocked
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', org_admin_email, 'role', 'authenticated')::text, true);
  BEGIN
    impact := public.admin_plan_change_impact(plan_with_subs, '{"max_groups": 5}'::jsonb);
    RAISE EXCEPTION 'FAIL: admin_plan_change_impact succeeded for an org_admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN
      RAISE EXCEPTION 'FAIL: org_admin admin_plan_change_impact raised "%", expected KITPAT_INSUFFICIENT_ROLE', err;
    END IF;
  END;

  --------------------------------------------- 2b. owner: reduced + warning=true
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  impact := public.admin_plan_change_impact(plan_with_subs, '{"max_groups": 5}'::jsonb);
  IF (impact -> 'reduced_keys' -> 'max_groups' ->> 'old') <> '10' OR (impact -> 'reduced_keys' -> 'max_groups' ->> 'new') <> '5' THEN
    RAISE EXCEPTION 'FAIL: admin_plan_change_impact reduced_keys = %, expected max_groups old=10 new=5', impact -> 'reduced_keys';
  END IF;
  IF (impact ->> 'warning')::boolean IS NOT true THEN
    RAISE EXCEPTION 'FAIL: admin_plan_change_impact warning = %, expected true (reduced limit + an active subscriber)', impact ->> 'warning';
  END IF;
  IF (impact ->> 'active_subscribers')::integer <> 1 THEN
    RAISE EXCEPTION 'FAIL: admin_plan_change_impact active_subscribers = %, expected 1', impact ->> 'active_subscribers';
  END IF;

  --------------------------------------------- 2c. owner: reduced + warning=false (no subs)
  impact := public.admin_plan_change_impact(plan_without_subs, '{"max_groups": 5}'::jsonb);
  IF (impact -> 'reduced_keys' -> 'max_groups') IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_plan_change_impact (no-subs plan) did not report the lowered max_groups in reduced_keys: %', impact;
  END IF;
  IF (impact ->> 'warning')::boolean IS NOT false THEN
    RAISE EXCEPTION 'FAIL: admin_plan_change_impact (no-subs plan) warning = %, expected false (no active subscribers)', impact ->> 'warning';
  END IF;
  RAISE NOTICE 'PASS: admin_plan_change_impact raises KITPAT_INSUFFICIENT_ROLE for org_admin, and for owner reports a lowered limit with warning=true when subscribers exist and warning=false when none do';

  ------------------------------------------------------- 3. slug guard trigger
  BEGIN
    UPDATE public.plans SET slug = 'ap6-renamed-' || substr(gen_random_uuid()::text, 1, 8) WHERE id = plan_with_subs;
    RAISE EXCEPTION 'FAIL: renaming the slug of a plan with an active subscription succeeded';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_PLAN_SLUG_LOCKED' THEN
      RAISE EXCEPTION 'FAIL: slug rename on a plan with an active subscription raised "%", expected KITPAT_PLAN_SLUG_LOCKED', err;
    END IF;
  END;

  UPDATE public.plans SET price_monthly = price_monthly + 1 WHERE id = plan_with_subs;
  IF (SELECT price_monthly FROM public.plans WHERE id = plan_with_subs) <> 200 THEN
    RAISE EXCEPTION 'FAIL: price_monthly update on the same (slug-locked) plan did not succeed';
  END IF;
  RAISE NOTICE 'PASS: updating slug on a plan with an active subscription raises KITPAT_PLAN_SLUG_LOCKED; updating price_monthly on the same plan succeeds';

  --------------------------------------------------- 4. admin_list_subscriptions
  SELECT * INTO row_rec FROM public.admin_list_subscriptions(plan_with_subs, 50, 0) WHERE user_id = user_with_sub;
  IF row_rec.user_id IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_list_subscriptions did not return the fixture subscription';
  END IF;
  IF row_rec.masked_phone = '9123456780' OR row_rec.masked_phone !~ '^\+91X+\d{2}$' THEN
    RAISE EXCEPTION 'FAIL: admin_list_subscriptions masked_phone = %, expected a masked +91X...NN value, never the raw phone', row_rec.masked_phone;
  END IF;
  RAISE NOTICE 'PASS: admin_list_subscriptions returns a masked phone and never a raw one';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
