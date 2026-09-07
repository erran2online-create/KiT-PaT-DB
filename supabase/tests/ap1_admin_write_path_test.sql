-- AP1 test: admin_can_write role/table rule, and log_admin_action's new
-- actor-override parameters.
--
-- SQL side only. The admin-write edge function itself is NOT SQL-testable
-- here -- it is not exercised or asserted by this file at all. Its
-- correctness (JWT verification, admins lookup, table/op/role gating,
-- before/after capture, log_admin_action call) has not been tested in this
-- session; state that plainly rather than claiming otherwise.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the AP1 migration
-- (20260907010000_ap1_admin_write_path.sql) applied (which in turn
-- requires AP0, 20260906030000, already applied).
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap1_admin_write_path_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. admin_can_write() is false for a non-admin, for every allow-listed
--      table.
--   2. admin_can_write() is true for an owner, for every allow-listed
--      table.
--   3. admin_can_write() is true for an org_admin on the 6 non-plans
--      tables, and false on 'plans'.
--   4. admin_can_write() is false for role='member', for every
--      allow-listed table (including plans).
--   5. log_admin_action's new p_actor_admin_id/p_actor_email params, when
--      explicitly supplied, are used verbatim instead of auto-detecting
--      the actor from auth.jwt() -- the path the admin-write edge
--      function relies on.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap1.owner.test@kitpat.in';
  org_admin_email text := 'ap1.orgadmin.test@kitpat.in';
  member_email text := 'ap1.member.test@kitpat.in';
  nonadmin_email text := 'not-an-admin@example.com';
  owner_id uuid;
  tables text[] := ARRAY[
    'badge_definitions', 'invite_templates', 'plans', 'game_theme_packs',
    'festival_themes', 'greeting_variants', 'tambola_variants'
  ];
  tbl text;
  result boolean;
  logged_row public.admin_audit;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES
    (owner_email, 'owner', true),
    (org_admin_email, 'org_admin', true),
    (member_email, 'member', true)
  ON CONFLICT (email) DO UPDATE SET role = EXCLUDED.role, is_active = true;

  SELECT id INTO owner_id FROM public.admins WHERE email = owner_email;

  ------------------------------------------------------------- 1. non-admin
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', nonadmin_email, 'role', 'authenticated')::text, true);
  FOREACH tbl IN ARRAY tables LOOP
    result := public.admin_can_write(tbl);
    IF result IS NOT FALSE THEN
      RAISE EXCEPTION 'FAIL: admin_can_write(%) = % for a non-admin, expected false', tbl, result;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: admin_can_write() is false for a non-admin, for every allow-listed table';

  ---------------------------------------------------------------- 2. owner
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  FOREACH tbl IN ARRAY tables LOOP
    result := public.admin_can_write(tbl);
    IF result IS NOT TRUE THEN
      RAISE EXCEPTION 'FAIL: admin_can_write(%) = % for an owner, expected true', tbl, result;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: admin_can_write() is true for an owner, for every allow-listed table';

  ------------------------------------------------------------- 3. org_admin
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', org_admin_email, 'role', 'authenticated')::text, true);
  FOREACH tbl IN ARRAY tables LOOP
    result := public.admin_can_write(tbl);
    IF tbl = 'plans' THEN
      IF result IS NOT FALSE THEN
        RAISE EXCEPTION 'FAIL: admin_can_write(plans) = % for an org_admin, expected false', result;
      END IF;
    ELSE
      IF result IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: admin_can_write(%) = % for an org_admin, expected true', tbl, result;
      END IF;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: admin_can_write() is true for an org_admin on the 6 non-plans tables, and false on plans';

  --------------------------------------------------------------- 4. member
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', member_email, 'role', 'authenticated')::text, true);
  FOREACH tbl IN ARRAY tables LOOP
    result := public.admin_can_write(tbl);
    IF result IS NOT FALSE THEN
      RAISE EXCEPTION 'FAIL: admin_can_write(%) = % for role=member, expected false', tbl, result;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: admin_can_write() is false for role=member, for every allow-listed table';

  ------------------------------------------------- 5. log_admin_action actor override
  SET LOCAL ROLE service_role;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'service_role')::text, true);
  logged_row := public.log_admin_action(
    'update:plans', 'plans', 'some-plan-id', '{"tier":"free"}'::jsonb, '{"tier":"elite"}'::jsonb,
    false, NULL, NULL, owner_id, owner_email
  );
  RESET ROLE;

  IF logged_row.actor_admin_id IS DISTINCT FROM owner_id OR logged_row.actor_email IS DISTINCT FROM owner_email THEN
    RAISE EXCEPTION 'FAIL: log_admin_action ignored the explicit actor override (actor_admin_id=%, actor_email=%, expected %/%)',
      logged_row.actor_admin_id, logged_row.actor_email, owner_id, owner_email;
  END IF;
  RAISE NOTICE 'PASS: log_admin_action uses the explicit p_actor_admin_id/p_actor_email override verbatim -- the path the admin-write edge function relies on';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
  RAISE NOTICE 'NOTE: the admin-write edge function itself was NOT tested here -- it is not SQL-testable. Only admin_can_write() and log_admin_action() (its two SQL dependencies) were exercised.';
END;
$t$;

ROLLBACK;
