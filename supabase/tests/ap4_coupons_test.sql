-- AP4 test: coupons/coupon_targets/coupon_redemptions and the
-- validate_coupon/redeem_coupon RPCs.
--
-- Razorpay is NOT SQL-testable and is NOT exercised or asserted anywhere in
-- this file -- stated plainly rather than claiming it was tested. Only the
-- redemption bookkeeping (razorpay_required flag, redemption_count,
-- coupon_redemptions row) is proven here.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0, AP2 (public.users.email) and this
-- migration (20260907060000_ap4_coupons.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap4_coupons_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. razorpay_required is true for percent/flat, false for
--      free_months/free, and cannot be set independently (GENERATED
--      ALWAYS rejects an explicit value on INSERT).
--   2. A percent coupon with value 150 is rejected by the CHECK.
--   3. validate_coupon returns valid=false with a reason for expired,
--      exhausted, already-redeemed and not-targeted cases.
--   4. redeem_coupon increments redemption_count exactly once; a second
--      attempt by the same user raises KITPAT_COUPON_ALREADY_REDEEMED.
--   5. A targeted coupon is not eligible for a non-targeted user
--      (redeem_coupon raises KITPAT_COUPON_NOT_ELIGIBLE).
--   6. Direct client SELECT on coupons fails (authenticated and anon).
--   7. A user can read their own coupon_redemptions but not another
--      user's.
--   8. admin_can_write says owner-only for both coupon tables.

BEGIN;

DO $t$
DECLARE
  user_a uuid;
  user_b uuid;
  coupon_percent_id uuid;
  coupon_flat_id uuid;
  coupon_free_months_id uuid;
  coupon_free_id uuid;
  coupon_expired_id uuid;
  coupon_exhausted_id uuid;
  coupon_targeted_id uuid;
  free_code text := 'AP4_FREE_' || substr(gen_random_uuid()::text, 1, 8);
  expired_code text := 'AP4_EXPIRED_' || substr(gen_random_uuid()::text, 1, 8);
  exhausted_code text := 'AP4_EXHAUSTED_' || substr(gen_random_uuid()::text, 1, 8);
  targeted_code text := 'AP4_TARGETED_' || substr(gen_random_uuid()::text, 1, 8);
  err text;
  err_sqlstate text;
  result jsonb;
  row_count integer;
  write_blocked boolean;
  owner_email text := 'ap4.owner.test@kitpat.in';
  org_admin_email text := 'ap4.orgadmin.test@kitpat.in';
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (name, phone, email, city) VALUES ('AP4 User A', '9000000001', 'ap4.a@realmail.com', 'Pune') RETURNING id INTO user_a;
  INSERT INTO public.users (name, phone, email, city) VALUES ('AP4 User B', '9000000002', 'ap4.b@realmail.com', 'Pune') RETURNING id INTO user_b;

  ------------------------------------------------ 1. razorpay_required derivation
  INSERT INTO public.coupons (code, type, value) VALUES ('AP4_PCT_' || substr(gen_random_uuid()::text, 1, 8), 'percent', 20) RETURNING id INTO coupon_percent_id;
  INSERT INTO public.coupons (code, type, value) VALUES ('AP4_FLAT_' || substr(gen_random_uuid()::text, 1, 8), 'flat', 100) RETURNING id INTO coupon_flat_id;
  INSERT INTO public.coupons (code, type, value) VALUES ('AP4_FM_' || substr(gen_random_uuid()::text, 1, 8), 'free_months', 3) RETURNING id INTO coupon_free_months_id;
  INSERT INTO public.coupons (code, type, value) VALUES ('AP4_FREEBASE_' || substr(gen_random_uuid()::text, 1, 8), 'free', NULL) RETURNING id INTO coupon_free_id;

  IF (SELECT razorpay_required FROM public.coupons WHERE id = coupon_percent_id) IS NOT true THEN
    RAISE EXCEPTION 'FAIL: razorpay_required is not true for a percent coupon';
  END IF;
  IF (SELECT razorpay_required FROM public.coupons WHERE id = coupon_flat_id) IS NOT true THEN
    RAISE EXCEPTION 'FAIL: razorpay_required is not true for a flat coupon';
  END IF;
  IF (SELECT razorpay_required FROM public.coupons WHERE id = coupon_free_months_id) IS NOT false THEN
    RAISE EXCEPTION 'FAIL: razorpay_required is not false for a free_months coupon';
  END IF;
  IF (SELECT razorpay_required FROM public.coupons WHERE id = coupon_free_id) IS NOT false THEN
    RAISE EXCEPTION 'FAIL: razorpay_required is not false for a free coupon';
  END IF;

  BEGIN
    INSERT INTO public.coupons (code, type, value, razorpay_required)
    VALUES ('AP4_BADGEN_' || substr(gen_random_uuid()::text, 1, 8), 'percent', 10, false);
    RAISE EXCEPTION 'FAIL: coupons accepted an explicit razorpay_required value on INSERT (should be GENERATED ALWAYS)';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS err_sqlstate = RETURNED_SQLSTATE;
    IF err_sqlstate <> '428C9' THEN
      RAISE EXCEPTION 'FAIL: inserting an explicit razorpay_required raised SQLSTATE %, expected 428C9 (generated_always)', err_sqlstate;
    END IF;
  END;
  RAISE NOTICE 'PASS: razorpay_required is derived correctly (true for percent/flat, false for free_months/free) and cannot be set independently';

  --------------------------------------------------------- 2. percent > 100
  BEGIN
    INSERT INTO public.coupons (code, type, value) VALUES ('AP4_OVER100_' || substr(gen_random_uuid()::text, 1, 8), 'percent', 150);
    RAISE EXCEPTION 'FAIL: coupons accepted a percent coupon with value 150';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  RAISE NOTICE 'PASS: a percent coupon with value 150 is rejected by the CHECK';

  ---------------------------------------------------------------- fixtures cont'd
  INSERT INTO public.coupons (code, type, value, is_active, expires_at)
  VALUES (expired_code, 'free_months', 1, true, now() - interval '1 day')
  RETURNING id INTO coupon_expired_id;

  INSERT INTO public.coupons (code, type, value, is_active, max_redemptions, redemption_count)
  VALUES (exhausted_code, 'free_months', 1, true, 1, 1)
  RETURNING id INTO coupon_exhausted_id;

  INSERT INTO public.coupons (code, type, value, is_active)
  VALUES (free_code, 'free_months', 1, true)
  RETURNING id INTO coupon_free_id;

  INSERT INTO public.coupons (code, type, value, is_active)
  VALUES (targeted_code, 'free_months', 1, true)
  RETURNING id INTO coupon_targeted_id;
  INSERT INTO public.coupon_targets (coupon_id, user_id) VALUES (coupon_targeted_id, user_b);

  ------------------------------------------------------- 3. validate_coupon reasons
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_a::text, 'role', 'authenticated')::text, true);

  result := public.validate_coupon(expired_code);
  IF (result ->> 'valid')::boolean IS NOT false OR (result ->> 'reason') <> 'KITPAT_COUPON_EXPIRED' THEN
    RAISE EXCEPTION 'FAIL: validate_coupon(expired) = %, expected valid=false reason=KITPAT_COUPON_EXPIRED', result;
  END IF;

  result := public.validate_coupon(exhausted_code);
  IF (result ->> 'valid')::boolean IS NOT false OR (result ->> 'reason') <> 'KITPAT_COUPON_EXHAUSTED' THEN
    RAISE EXCEPTION 'FAIL: validate_coupon(exhausted) = %, expected valid=false reason=KITPAT_COUPON_EXHAUSTED', result;
  END IF;

  result := public.validate_coupon(targeted_code);
  IF (result ->> 'valid')::boolean IS NOT false OR (result ->> 'reason') <> 'KITPAT_COUPON_INVALID' THEN
    RAISE EXCEPTION 'FAIL: validate_coupon(targeted, non-targeted user) = %, expected valid=false reason=KITPAT_COUPON_INVALID (masked)', result;
  END IF;

  result := public.validate_coupon(free_code);
  IF (result ->> 'valid')::boolean IS NOT true THEN
    RAISE EXCEPTION 'FAIL: validate_coupon(free_code) for an untargeted, unredeemed, active coupon = %, expected valid=true', result;
  END IF;
  RAISE NOTICE 'PASS: validate_coupon returns valid=false with the right reason for expired/exhausted/not-targeted, and valid=true for an eligible coupon';

  --------------------------------------------------- 4. redeem_coupon + double redeem
  result := public.redeem_coupon(free_code);
  IF (result ->> 'redeemed')::boolean IS NOT true THEN
    RAISE EXCEPTION 'FAIL: redeem_coupon(free_code) did not report redeemed=true: %', result;
  END IF;

  IF (SELECT redemption_count FROM public.coupons WHERE id = coupon_free_id) <> 1 THEN
    RAISE EXCEPTION 'FAIL: redemption_count = %, expected 1 after one redemption', (SELECT redemption_count FROM public.coupons WHERE id = coupon_free_id);
  END IF;

  result := public.validate_coupon(free_code);
  IF (result ->> 'valid')::boolean IS NOT false OR (result ->> 'reason') <> 'KITPAT_COUPON_ALREADY_REDEEMED' THEN
    RAISE EXCEPTION 'FAIL: validate_coupon(free_code) after redemption = %, expected valid=false reason=KITPAT_COUPON_ALREADY_REDEEMED', result;
  END IF;

  BEGIN
    result := public.redeem_coupon(free_code);
    RAISE EXCEPTION 'FAIL: redeem_coupon(free_code) succeeded on a second redemption by the same user';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_COUPON_ALREADY_REDEEMED' THEN
      RAISE EXCEPTION 'FAIL: second redeem_coupon(free_code) raised "%", expected KITPAT_COUPON_ALREADY_REDEEMED', err;
    END IF;
  END;

  IF (SELECT redemption_count FROM public.coupons WHERE id = coupon_free_id) <> 1 THEN
    RAISE EXCEPTION 'FAIL: redemption_count = %, expected to still be 1 after the rejected second attempt', (SELECT redemption_count FROM public.coupons WHERE id = coupon_free_id);
  END IF;
  RAISE NOTICE 'PASS: redeem_coupon increments redemption_count exactly once; a second attempt by the same user raises KITPAT_COUPON_ALREADY_REDEEMED';

  ------------------------------------------------------- 5. targeted coupon eligibility
  BEGIN
    result := public.redeem_coupon(targeted_code);
    RAISE EXCEPTION 'FAIL: redeem_coupon(targeted_code) succeeded for a non-targeted user';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_COUPON_NOT_ELIGIBLE' THEN
      RAISE EXCEPTION 'FAIL: redeem_coupon(targeted_code) for a non-targeted user raised "%", expected KITPAT_COUPON_NOT_ELIGIBLE', err;
    END IF;
  END;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_b::text, 'role', 'authenticated')::text, true);
  result := public.redeem_coupon(targeted_code);
  IF (result ->> 'redeemed')::boolean IS NOT true THEN
    RAISE EXCEPTION 'FAIL: redeem_coupon(targeted_code) for the targeted user did not succeed: %', result;
  END IF;
  RAISE NOTICE 'PASS: a targeted coupon is not eligible for a non-targeted user, and succeeds for the targeted one';

  ------------------------------------------------------------ 6. direct SELECT blocked
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM 1 FROM public.coupons LIMIT 1;
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: authenticated could SELECT public.coupons directly';
  END IF;

  SET LOCAL ROLE anon;
  BEGIN
    PERFORM 1 FROM public.coupons LIMIT 1;
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: anon could SELECT public.coupons directly';
  END IF;
  RAISE NOTICE 'PASS: direct client SELECT on coupons fails for authenticated and anon';

  --------------------------------------------------- 7. coupon_redemptions RLS
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_a::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO row_count FROM public.coupon_redemptions WHERE coupon_id = coupon_free_id AND user_id = user_a;
  RESET ROLE;
  IF row_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: user_a could not see their own coupon_redemptions row (count=%)', row_count;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_a::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO row_count FROM public.coupon_redemptions WHERE coupon_id = coupon_targeted_id AND user_id = user_b;
  RESET ROLE;
  IF row_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: user_a could see user_b''s coupon_redemptions row (count=%), expected 0 (RLS should filter it out)', row_count;
  END IF;
  RAISE NOTICE 'PASS: a user can read their own coupon_redemptions but not another user''s';

  ------------------------------------------------------- 8. admin_can_write owner-only
  INSERT INTO public.admins (email, role, is_active) VALUES
    (owner_email, 'owner', true),
    (org_admin_email, 'org_admin', true)
  ON CONFLICT (email) DO UPDATE SET role = EXCLUDED.role, is_active = true;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  IF NOT public.admin_can_write('coupons') OR NOT public.admin_can_write('coupon_targets') THEN
    RAISE EXCEPTION 'FAIL: admin_can_write is false for owner on coupons/coupon_targets, expected true';
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', org_admin_email, 'role', 'authenticated')::text, true);
  IF public.admin_can_write('coupons') OR public.admin_can_write('coupon_targets') THEN
    RAISE EXCEPTION 'FAIL: admin_can_write is true for org_admin on coupons/coupon_targets, expected false (owner-only)';
  END IF;
  RAISE NOTICE 'PASS: admin_can_write is owner-only for both coupons and coupon_targets';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
  RAISE NOTICE 'NOTE: Razorpay itself was NOT exercised or asserted here -- not SQL-testable.';
END;
$t$;

ROLLBACK;
