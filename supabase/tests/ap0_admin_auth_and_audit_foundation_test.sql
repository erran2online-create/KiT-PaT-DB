-- AP0 test: admin auth + audit foundation, plus the plan-name neutraliser.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the AP0 migration
-- (20260906030000_ap0_admin_auth_and_audit_foundation.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap0_admin_auth_and_audit_foundation_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. Inserting an admins row with a non-@kitpat.in email fails the CHECK.
--   2. The seeded aps@kitpat.in row exists with role='owner', is_active=true.
--   3. is_admin() / admin_role() / is_admin_owner() behave correctly for a
--      simulated owner vs a simulated non-admin.
--   4. An is_sensitive_reveal=true admin_audit row is visible to an owner
--      and hidden from a non-owner admin.
--   5. log_admin_action raises KITPAT_ADMIN_ONLY for a non-service_role
--      caller, and succeeds (inserting a row, resolving the actor) when
--      called as service_role.
--   6. plans Empress/Queen carry the new name_neutral/variant columns;
--      Free/Starter are untouched; existing name/slug are untouched
--      everywhere.

BEGIN;

DO $t$
DECLARE
  test_admin_email text := 'p40.test.owner@kitpat.in';
  test_nonadmin_email text := 'not-an-admin@example.com';
  owner_row public.admins;
  err text;
  role_val text;
  owner_flag boolean;
  admin_flag boolean;
  reveal_row_id uuid;
  visible_count integer;
  logged_row public.admin_audit;
  empress_row public.plans;
  queen_row public.plans;
  free_row public.plans;
  starter_row public.plans;
BEGIN
  ------------------------------------------------------------ 1. CHECK rejects
  BEGIN
    INSERT INTO public.admins (email, role, is_active) VALUES ('not-office@gmail.com', 'member', true);
    RAISE EXCEPTION 'FAIL: an admins row with a non-@kitpat.in email was accepted';
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;
  RAISE NOTICE 'PASS: an admins row with a non-@kitpat.in email is rejected by the CHECK constraint';

  ------------------------------------------------------------ 2. seeded owner
  SELECT * INTO owner_row FROM public.admins WHERE email = 'aps@kitpat.in';
  IF owner_row.email IS NULL THEN
    RAISE EXCEPTION 'FAIL: the seeded aps@kitpat.in admins row does not exist';
  END IF;
  IF owner_row.role <> 'owner' OR owner_row.is_active <> true THEN
    RAISE EXCEPTION 'FAIL: aps@kitpat.in has role=%, is_active=%, expected owner/true', owner_row.role, owner_row.is_active;
  END IF;
  RAISE NOTICE 'PASS: the seeded aps@kitpat.in admins row exists with role=owner, is_active=true';

  ------------------------------------------------ 3. is_admin/admin_role/is_admin_owner
  -- Fixture: a second, non-owner admin, for the "active admin but not
  -- owner" half of the reveal-visibility test below.
  INSERT INTO public.admins (email, role, is_active) VALUES (test_admin_email, 'member', true)
  ON CONFLICT (email) DO UPDATE SET role = 'member', is_active = true;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', 'aps@kitpat.in', 'role', 'authenticated')::text, true);
  admin_flag := public.is_admin();
  role_val := public.admin_role();
  owner_flag := public.is_admin_owner();
  IF admin_flag IS NOT TRUE OR role_val <> 'owner' OR owner_flag IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: for the seeded owner, is_admin()=%, admin_role()=%, is_admin_owner()=%, expected true/owner/true', admin_flag, role_val, owner_flag;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', test_nonadmin_email, 'role', 'authenticated')::text, true);
  admin_flag := public.is_admin();
  role_val := public.admin_role();
  owner_flag := public.is_admin_owner();
  IF admin_flag IS NOT FALSE OR role_val IS NOT NULL OR owner_flag IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL: for a non-admin, is_admin()=%, admin_role()=%, is_admin_owner()=%, expected false/NULL/false', admin_flag, role_val, owner_flag;
  END IF;
  RAISE NOTICE 'PASS: is_admin()/admin_role()/is_admin_owner() are true/owner/true for the seeded owner and false/NULL/false for a non-admin';

  ------------------------------------------------------ 4. sensitive-reveal RLS
  INSERT INTO public.admin_audit (action, is_sensitive_reveal, revealed_field, revealed_subject)
  VALUES ('viewed_user_pii', true, 'phone', 'some-user-id')
  RETURNING id INTO reveal_row_id;

  INSERT INTO public.admin_audit (action, is_sensitive_reveal)
  VALUES ('viewed_dashboard', false);

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', 'aps@kitpat.in', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO visible_count FROM public.admin_audit WHERE id = reveal_row_id;
  RESET ROLE;
  IF visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: the owner cannot see the is_sensitive_reveal=true admin_audit row (visible_count=%)', visible_count;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', test_admin_email, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO visible_count FROM public.admin_audit WHERE id = reveal_row_id;
  RESET ROLE;
  IF visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: a non-owner active admin can see the is_sensitive_reveal=true admin_audit row (visible_count=%)', visible_count;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', test_admin_email, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO visible_count FROM public.admin_audit WHERE action = 'viewed_dashboard';
  RESET ROLE;
  IF visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: a non-owner active admin cannot see a non-reveal admin_audit row (visible_count=%)', visible_count;
  END IF;
  RAISE NOTICE 'PASS: an is_sensitive_reveal=true admin_audit row is visible to an owner, hidden from a non-owner active admin, and non-reveal rows are visible to any active admin';

  --------------------------------------------------- 5. log_admin_action guard
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', test_admin_email, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    logged_row := public.log_admin_action('unauthorized_attempt', 'test', 'x', NULL, NULL);
    RAISE EXCEPTION 'FAIL: log_admin_action succeeded for a non-service_role caller';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RESET ROLE;
      RAISE EXCEPTION 'FAIL: non-service_role log_admin_action call raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;
  RESET ROLE;

  SET LOCAL ROLE service_role;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', 'aps@kitpat.in', 'role', 'service_role')::text, true);
  logged_row := public.log_admin_action('granted_plan_override', 'plan', 'some-plan-id', '{"tier":"free"}'::jsonb, '{"tier":"elite"}'::jsonb);
  RESET ROLE;

  IF logged_row.id IS NULL THEN
    RAISE EXCEPTION 'FAIL: log_admin_action as service_role did not return an inserted row';
  END IF;
  IF logged_row.actor_email <> 'aps@kitpat.in' OR logged_row.actor_admin_id <> owner_row.id THEN
    RAISE EXCEPTION 'FAIL: log_admin_action did not resolve the actor from the caller''s admins record (actor_email=%, actor_admin_id=%)', logged_row.actor_email, logged_row.actor_admin_id;
  END IF;
  RAISE NOTICE 'PASS: log_admin_action raises KITPAT_ADMIN_ONLY for a non-service_role caller, and succeeds (inserting a row and resolving the actor) when called as service_role';

  --------------------------------------------------- 6. plan name neutraliser
  SELECT * INTO empress_row FROM public.plans WHERE name = 'Empress';
  SELECT * INTO queen_row FROM public.plans WHERE name = 'Queen';
  SELECT * INTO free_row FROM public.plans WHERE name = 'Free';
  SELECT * INTO starter_row FROM public.plans WHERE name = 'Starter';

  IF empress_row.name_neutral <> 'Elite' OR empress_row.name_variant_female <> 'Empress' OR empress_row.name_variant_male <> 'Emperor' THEN
    RAISE EXCEPTION 'FAIL: Empress plan variants = neutral=%, female=%, male=%, expected Elite/Empress/Emperor', empress_row.name_neutral, empress_row.name_variant_female, empress_row.name_variant_male;
  END IF;
  IF empress_row.name <> 'Empress' OR empress_row.slug IS NULL THEN
    RAISE EXCEPTION 'FAIL: Empress plan name/slug changed unexpectedly (name=%, slug=%)', empress_row.name, empress_row.slug;
  END IF;

  IF queen_row.name_neutral <> 'Champion' OR queen_row.name_variant_female <> 'Queen' OR queen_row.name_variant_male <> 'King' THEN
    RAISE EXCEPTION 'FAIL: Queen plan variants = neutral=%, female=%, male=%, expected Champion/Queen/King', queen_row.name_neutral, queen_row.name_variant_female, queen_row.name_variant_male;
  END IF;
  IF queen_row.name <> 'Queen' OR queen_row.slug IS NULL THEN
    RAISE EXCEPTION 'FAIL: Queen plan name/slug changed unexpectedly (name=%, slug=%)', queen_row.name, queen_row.slug;
  END IF;

  IF free_row.name_neutral IS NOT NULL OR free_row.name_variant_female IS NOT NULL OR free_row.name_variant_male IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: Free plan gained variant columns, expected all NULL';
  END IF;
  IF starter_row.name_neutral IS NOT NULL OR starter_row.name_variant_female IS NOT NULL OR starter_row.name_variant_male IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: Starter plan gained variant columns, expected all NULL';
  END IF;
  RAISE NOTICE 'PASS: Empress/Queen carry the expected name_neutral/variant columns with name/slug untouched; Free/Starter are unchanged';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
