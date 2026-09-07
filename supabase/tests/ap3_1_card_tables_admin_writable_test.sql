-- AP3.1 test: admin_can_write allows festival_cards/promo_cards for
-- org_admin and owner (not member), without disturbing the existing
-- table/role rules.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0, AP1, and this migration
-- (20260907050000_ap3_1_card_tables_admin_writable.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap3_1_card_tables_admin_writable_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. admin_can_write(festival_cards)/(promo_cards) is true for owner and
--      org_admin, false for member.
--   2. It is false for a non-admin (no admins row at all).
--   3. 'plans' is still owner-only (org_admin gets false).
--   4. The 5 other original AP1 tables still behave exactly as before:
--      true for owner and org_admin, false for member.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap31.owner.test@kitpat.in';
  org_admin_email text := 'ap31.orgadmin.test@kitpat.in';
  member_email text := 'ap31.member.test@kitpat.in';
  non_admin_email text := 'ap31.notadmin.test@kitpat.in';
  org_admin_writable_tables text[] := ARRAY[
    'badge_definitions', 'invite_templates', 'game_theme_packs',
    'festival_themes', 'greeting_variants', 'tambola_variants',
    'festival_cards', 'promo_cards'
  ];
  owner_only_tables text[] := ARRAY['plans'];
  tbl text;
  result boolean;
BEGIN
  INSERT INTO public.admins (email, role, is_active) VALUES
    (owner_email, 'owner', true),
    (org_admin_email, 'org_admin', true),
    (member_email, 'member', true)
  ON CONFLICT (email) DO UPDATE SET role = EXCLUDED.role, is_active = true;

  ------------------------------------------------------------ 1a. owner: all true
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  FOREACH tbl IN ARRAY (org_admin_writable_tables || owner_only_tables) LOOP
    result := public.admin_can_write(tbl);
    IF NOT result THEN
      RAISE EXCEPTION 'FAIL: admin_can_write(%) = false for owner, expected true', tbl;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: owner can write every allow-listed table, including festival_cards and promo_cards';

  --------------------------------------------- 1b. org_admin: all but plans
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', org_admin_email, 'role', 'authenticated')::text, true);
  FOREACH tbl IN ARRAY org_admin_writable_tables LOOP
    result := public.admin_can_write(tbl);
    IF NOT result THEN
      RAISE EXCEPTION 'FAIL: admin_can_write(%) = false for org_admin, expected true', tbl;
    END IF;
  END LOOP;
  FOREACH tbl IN ARRAY owner_only_tables LOOP
    result := public.admin_can_write(tbl);
    IF result THEN
      RAISE EXCEPTION 'FAIL: admin_can_write(%) = true for org_admin, expected false (owner-only)', tbl;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: org_admin can write festival_cards/promo_cards and every other non-owner-only table, but not plans (3. still owner-only)';

  ------------------------------------------------------------- 1c. member: none
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', member_email, 'role', 'authenticated')::text, true);
  FOREACH tbl IN ARRAY (org_admin_writable_tables || owner_only_tables) LOOP
    result := public.admin_can_write(tbl);
    IF result THEN
      RAISE EXCEPTION 'FAIL: admin_can_write(%) = true for member, expected false', tbl;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: member cannot write any allow-listed table, including festival_cards and promo_cards';

  ------------------------------------------------------------- 2. non-admin
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', non_admin_email, 'role', 'authenticated')::text, true);
  IF public.admin_can_write('festival_cards') THEN
    RAISE EXCEPTION 'FAIL: admin_can_write(festival_cards) = true for a non-admin, expected false';
  END IF;
  IF public.admin_can_write('promo_cards') THEN
    RAISE EXCEPTION 'FAIL: admin_can_write(promo_cards) = true for a non-admin, expected false';
  END IF;
  RAISE NOTICE 'PASS: a non-admin cannot write festival_cards or promo_cards';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
