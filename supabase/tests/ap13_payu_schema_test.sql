-- AP13 test: PayU plan-id columns, payment_events (service_role only, no
-- client policy), its UNIQUE(provider, provider_event_id) guard, and
-- admin_list_payment_events.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0-AP12 and this migration
-- (20260909050000_ap13_payu_schema.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap13_payu_schema_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. plans.payu_plan_id_monthly/yearly exist, are nullable, default
--      NULL, and the existing razorpay_plan_id_monthly/yearly columns are
--      untouched.
--   b. payment_events exists with RLS enabled and ZERO policies.
--   c. Neither anon nor authenticated holds any privilege on
--      payment_events.
--   d. The UNIQUE(provider, provider_event_id) index rejects a duplicate.
--   e. admin_list_payment_events raises KITPAT_ADMIN_ONLY for a non-admin
--      and returns rows for an active admin.
--   f. admin_list_payment_events does not return a payload column.
--   g. anon holds no EXECUTE on admin_list_payment_events.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap13.owner.test@kitpat.in';
  non_admin_email text := 'ap13.notadmin.test@kitpat.in';
  col record;
  plans_col_count integer := 0;
  razorpay_col_count integer := 0;
  rls_enabled boolean;
  policy_count integer;
  anon_priv boolean;
  authenticated_priv boolean;
  event_id_1 uuid;
  err text;
  found_row boolean;
  payload_arg_present boolean;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES (owner_email, 'owner', true)
  ON CONFLICT (email) DO UPDATE SET role = 'owner', is_active = true;

  --------------------------------------------------------- a. plans columns
  FOR col IN
    SELECT column_name, is_nullable, column_default
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'plans'
      AND column_name IN ('payu_plan_id_monthly', 'payu_plan_id_yearly')
  LOOP
    IF col.is_nullable <> 'YES' OR col.column_default IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL: plans.% is_nullable=%, default=%, expected nullable with no default', col.column_name, col.is_nullable, col.column_default;
    END IF;
    plans_col_count := plans_col_count + 1;
  END LOOP;
  IF plans_col_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: found % of the 2 expected payu_plan_id_* columns on plans, expected 2', plans_col_count;
  END IF;

  SELECT count(*) INTO razorpay_col_count
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'plans'
    AND column_name IN ('razorpay_plan_id_monthly', 'razorpay_plan_id_yearly');
  IF razorpay_col_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: razorpay_plan_id_monthly/yearly = % columns found, expected both still present (untouched)', razorpay_col_count;
  END IF;
  RAISE NOTICE 'PASS: payu_plan_id_monthly/yearly exist (nullable, no default) and the razorpay columns are untouched';

  --------------------------------------------------- b. payment_events RLS shape
  SELECT relrowsecurity INTO rls_enabled FROM pg_class WHERE relname = 'payment_events' AND relnamespace = 'public'::regnamespace;
  IF rls_enabled IS NOT true THEN
    RAISE EXCEPTION 'FAIL: payment_events RLS is not enabled';
  END IF;

  SELECT count(*) INTO policy_count FROM pg_policies WHERE schemaname = 'public' AND tablename = 'payment_events';
  IF policy_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: payment_events has % policies, expected 0', policy_count;
  END IF;
  RAISE NOTICE 'PASS: payment_events exists with RLS enabled and zero policies';

  ------------------------------------------------------- c. no client privilege
  SELECT has_table_privilege('anon', 'public.payment_events', 'SELECT') INTO anon_priv;
  SELECT has_table_privilege('authenticated', 'public.payment_events', 'SELECT') INTO authenticated_priv;
  IF anon_priv IS NOT false OR authenticated_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon/authenticated SELECT privilege on payment_events = %/%, expected false/false', anon_priv, authenticated_priv;
  END IF;

  SELECT has_table_privilege('anon', 'public.payment_events', 'INSERT') INTO anon_priv;
  SELECT has_table_privilege('authenticated', 'public.payment_events', 'INSERT') INTO authenticated_priv;
  IF anon_priv IS NOT false OR authenticated_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon/authenticated INSERT privilege on payment_events = %/%, expected false/false', anon_priv, authenticated_priv;
  END IF;
  RAISE NOTICE 'PASS: neither anon nor authenticated holds any privilege on payment_events';

  --------------------------------------------------------- d. UNIQUE guard
  INSERT INTO public.payment_events (provider, event_type, provider_event_id, status)
  VALUES ('payu', 'payment.success', 'evt_ap13_dup_test', 'success')
  RETURNING id INTO event_id_1;

  BEGIN
    INSERT INTO public.payment_events (provider, event_type, provider_event_id, status)
    VALUES ('payu', 'payment.success', 'evt_ap13_dup_test', 'success');
    RAISE EXCEPTION 'FAIL: a duplicate (provider, provider_event_id) was accepted';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  -- A NULL provider_event_id must NOT collide (the partial index only
  -- applies WHERE provider_event_id IS NOT NULL).
  INSERT INTO public.payment_events (provider, event_type, status) VALUES ('payu', 'payment.pending', 'pending');
  INSERT INTO public.payment_events (provider, event_type, status) VALUES ('payu', 'payment.pending', 'pending');
  RAISE NOTICE 'PASS: UNIQUE(provider, provider_event_id) rejects a duplicate, and NULL provider_event_id rows do not collide';

  ------------------------------------------------ e. admin_list_payment_events
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', non_admin_email, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM * FROM public.admin_list_payment_events();
    RAISE EXCEPTION 'FAIL: admin_list_payment_events succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_list_payment_events raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  SELECT bool_or(id = event_id_1) INTO found_row FROM public.admin_list_payment_events(NULL, NULL, NULL, 100, 0);
  IF NOT coalesce(found_row, false) THEN
    RAISE EXCEPTION 'FAIL: admin_list_payment_events did not return the fixture payment_events row for an active admin';
  END IF;
  RAISE NOTICE 'PASS: admin_list_payment_events raises KITPAT_ADMIN_ONLY for a non-admin and returns rows for an active admin';

  -------------------------------------------------- f. no payload column returned
  SELECT (array_position(p.proargnames, 'payload') IS NOT NULL) INTO payload_arg_present
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'admin_list_payment_events';
  IF coalesce(payload_arg_present, false) THEN
    RAISE EXCEPTION 'FAIL: admin_list_payment_events exposes a payload column/argument, expected it excluded';
  END IF;
  RAISE NOTICE 'PASS: admin_list_payment_events does not return a payload column';

  --------------------------------------------------------------- g. anon lockout
  SELECT has_function_privilege('anon', 'public.admin_list_payment_events(text,uuid,text,int,int)', 'EXECUTE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_list_payment_events';
  END IF;
  RAISE NOTICE 'PASS: anon holds no EXECUTE on admin_list_payment_events';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
