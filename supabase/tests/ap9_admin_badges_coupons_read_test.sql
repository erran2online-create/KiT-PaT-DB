-- AP9 test: badge_definitions.is_active/sort_order, admin_list_coupons,
-- admin_coupon_detail, anon lockout on both new functions, and a badge
-- write producing an admin_audit row.
--
-- The admin-write edge function itself is NOT SQL-testable (same
-- disclaimer as AP1's own test) -- item (e) below exercises the same two
-- SQL-level steps admin-write performs for any allow-listed table (an
-- UPDATE, then log_admin_action with an explicit actor override), not the
-- Deno function itself.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0-AP8 and this migration
-- (20260909010000_ap9_admin_badges_coupons_read.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap9_admin_badges_coupons_read_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. badge_definitions.is_active exists, defaults true, and every
--      pre-existing row is true.
--   b. The member-facing badges read (badges_public_read, unfiltered by
--      is_active) still returns every badge row.
--   c. admin_list_coupons raises KITPAT_ADMIN_ONLY for a non-admin and
--      returns rows (including a fixture coupon) for an active admin.
--   d. anon holds no EXECUTE on admin_list_coupons or admin_coupon_detail.
--   e. A badge write (UPDATE + log_admin_action, admin-write's own
--      SQL-level pattern) produces an admin_audit row.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap9.owner.test@kitpat.in';
  non_admin_email text := 'ap9.notadmin.test@kitpat.in';
  owner_admin_id uuid;
  err text;
  default_expr text;
  inactive_count integer;
  total_badge_count integer;
  member_visible_count integer;
  coupon_id uuid;
  coupon_row record;
  found_coupon boolean;
  anon_has_execute boolean;
  any_badge_id uuid;
  before_row jsonb;
  after_row jsonb;
  audit_row public.admin_audit;
  audit_count integer;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES (owner_email, 'owner', true)
  ON CONFLICT (email) DO UPDATE SET role = 'owner', is_active = true;
  SELECT id INTO owner_admin_id FROM public.admins WHERE email = owner_email;

  --------------------------------------------------------- a. is_active column
  SELECT column_default INTO default_expr
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'badge_definitions' AND column_name = 'is_active';
  IF default_expr IS NULL OR default_expr NOT ILIKE 'true%' THEN
    RAISE EXCEPTION 'FAIL: badge_definitions.is_active default = %, expected true', default_expr;
  END IF;

  SELECT count(*) INTO inactive_count FROM public.badge_definitions WHERE is_active IS NOT true;
  IF inactive_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % badge_definitions row(s) are not is_active=true after the backfill', inactive_count;
  END IF;

  SELECT count(*) INTO total_badge_count FROM public.badge_definitions;
  IF total_badge_count = 0 THEN
    RAISE EXCEPTION 'FAIL: public.badge_definitions has no rows -- cannot meaningfully assert the backfill';
  END IF;
  RAISE NOTICE 'PASS: badge_definitions.is_active exists, defaults true, and all % existing rows are true', total_badge_count;

  --------------------------------------------------- b. member-facing read unaffected
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO member_visible_count FROM public.badge_definitions;
  RESET ROLE;
  IF member_visible_count <> total_badge_count THEN
    RAISE EXCEPTION 'FAIL: member-facing badge read returned % rows, expected all % (badges_public_read should be unfiltered by is_active)', member_visible_count, total_badge_count;
  END IF;
  RAISE NOTICE 'PASS: the member-facing badges read still returns every badge row';

  ------------------------------------------------------- c. admin_list_coupons
  INSERT INTO public.coupons (code, type, value, is_active)
  VALUES ('AP9_TEST_' || substr(gen_random_uuid()::text, 1, 8), 'free_months', 1, true)
  RETURNING id INTO coupon_id;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', non_admin_email, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM * FROM public.admin_list_coupons();
    RAISE EXCEPTION 'FAIL: admin_list_coupons succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_list_coupons raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  SELECT * INTO coupon_row FROM public.admin_list_coupons(NULL, 100, 0) WHERE id = coupon_id;
  IF coupon_row.id IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_list_coupons did not return the fixture coupon for an active admin';
  END IF;
  RAISE NOTICE 'PASS: admin_list_coupons raises KITPAT_ADMIN_ONLY for a non-admin and returns rows for an active admin';

  SELECT (public.admin_coupon_detail(coupon_id) ->> 'code') = coupon_row.code INTO found_coupon;
  IF NOT coalesce(found_coupon, false) THEN
    RAISE EXCEPTION 'FAIL: admin_coupon_detail did not return the fixture coupon''s code';
  END IF;

  --------------------------------------------------------------- d. anon lockout
  SELECT has_function_privilege('anon', 'public.admin_list_coupons(text,int,int)', 'EXECUTE') INTO anon_has_execute;
  IF anon_has_execute IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_list_coupons(text,int,int)';
  END IF;
  SELECT has_function_privilege('anon', 'public.admin_coupon_detail(uuid)', 'EXECUTE') INTO anon_has_execute;
  IF anon_has_execute IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_coupon_detail(uuid)';
  END IF;
  RAISE NOTICE 'PASS: anon holds no EXECUTE on admin_list_coupons or admin_coupon_detail';

  ------------------------------------------------------- e. badge write -> audit
  SELECT id INTO any_badge_id FROM public.badge_definitions ORDER BY id LIMIT 1;
  SELECT to_jsonb(b) INTO before_row FROM public.badge_definitions b WHERE b.id = any_badge_id;

  UPDATE public.badge_definitions SET sort_order = sort_order + 1 WHERE id = any_badge_id;

  SELECT to_jsonb(b) INTO after_row FROM public.badge_definitions b WHERE b.id = any_badge_id;

  SET LOCAL ROLE service_role;
  audit_row := public.log_admin_action(
    'update:badge_definitions', 'badge_definitions', any_badge_id::text,
    before_row, after_row, false, NULL, NULL, owner_admin_id, owner_email
  );
  RESET ROLE;

  SELECT count(*) INTO audit_count
  FROM public.admin_audit
  WHERE id = audit_row.id AND action = 'update:badge_definitions' AND target_id = any_badge_id::text;
  IF audit_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: the badge write (UPDATE + log_admin_action, admin-write''s own SQL-level pattern) did not produce an admin_audit row';
  END IF;
  RAISE NOTICE 'PASS: a badge write by an active admin produces an admin_audit row';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
  RAISE NOTICE 'NOTE: the admin-write edge function itself was NOT tested here -- not SQL-testable. Item (e) exercises the same UPDATE + log_admin_action steps it performs for any allow-listed table.';
END;
$t$;

ROLLBACK;
