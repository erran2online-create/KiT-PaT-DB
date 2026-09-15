-- P47 test: page_view's catalog seed, admin_web_analytics' role gate and
-- grouped rollup, anon's total lack of access, and that audit_events'
-- deny-client-write policy is untouched.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has this migration
-- (20260915040000_p47_web_analytics.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p47_web_analytics_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Item (a) note: the pre-existing catalog rows (17 as of this migration --
-- the original seed plus P45.2's 3 additions) are not enumerable from this
-- repo (no migration seeds the original rows, confirmed by grep in P45's
-- and P45.2's own PRs). As those PRs already established, this is proven
-- generically: re-running this migration's INSERT verbatim must not
-- change any existing row.
--
-- Proves:
--   a. page_view exists, category 'website', and re-running the seed
--      INSERT changes no existing row.
--   b. admin_web_analytics raises KITPAT_ADMIN_ONLY for a non-admin, and
--      returns correctly grouped rows for an active admin against seeded
--      audit_events fixtures.
--   c. anon holds no EXECUTE on admin_web_analytics and no privilege on
--      audit_events.
--   d. audit_events still rejects a direct client write.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'p47-owner@kitpat.in';
  outsider_id uuid;
  before_fingerprint text;
  after_fingerprint text;
  err text;
  row_count integer;
  in_row record;
  found_mumbai_home boolean := false;
  found_delhi_pricing boolean := false;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES (owner_email, 'owner', true)
    ON CONFLICT (email) DO UPDATE SET role = 'owner', is_active = true;
  INSERT INTO public.users (name, phone, city) VALUES ('P47 Outsider', '9922400001', 'Pune') RETURNING id INTO outsider_id;

  ------------------------------------------------------------ a. catalog seed
  IF NOT EXISTS (
    SELECT 1 FROM public.analytics_event_catalog
    WHERE event_name = 'page_view' AND category = 'website' AND contains_pii = false
  ) THEN
    RAISE EXCEPTION 'FAIL: page_view is missing, mis-categorized, or contains_pii is not false';
  END IF;

  SELECT string_agg(event_name || ':' || category || ':' || contains_pii::text, '|' ORDER BY event_name)
  INTO before_fingerprint
  FROM public.analytics_event_catalog;

  INSERT INTO public.analytics_event_catalog (event_name, category, description, required_properties, contains_pii)
  VALUES (
    'page_view', 'website',
    'A visit to a page on the kitpat.in marketing site. Carries which page (route) and a coarse location (country, region, city) -- never anything that identifies the visitor personally.',
    ARRAY['route', 'country'], false
  )
  ON CONFLICT (event_name) DO NOTHING;

  SELECT string_agg(event_name || ':' || category || ':' || contains_pii::text, '|' ORDER BY event_name)
  INTO after_fingerprint
  FROM public.analytics_event_catalog;

  IF before_fingerprint <> after_fingerprint THEN
    RAISE EXCEPTION 'FAIL: re-running the page_view seed INSERT changed at least one existing analytics_event_catalog row';
  END IF;
  RAISE NOTICE 'PASS: page_view exists with category website, and re-running the seed INSERT changes no existing row';

  ------------------------------------------------------ audit_events fixtures
  -- Written directly as the test superuser (bypassing RLS, exactly like
  -- service_role would), simulating what ingest-web-event itself inserts.
  INSERT INTO public.audit_events (user_id, event_name, source, properties, occurred_at) VALUES
    (NULL, 'page_view', 'web', jsonb_build_object('route', '/', 'country', 'IN', 'region', 'MH', 'city', 'Mumbai'), now()),
    (NULL, 'page_view', 'web', jsonb_build_object('route', '/', 'country', 'IN', 'region', 'MH', 'city', 'Mumbai'), now()),
    (NULL, 'page_view', 'web', jsonb_build_object('route', '/', 'country', 'IN', 'region', 'MH', 'city', 'Mumbai'), now()),
    (NULL, 'page_view', 'web', jsonb_build_object('route', '/pricing', 'country', 'IN', 'region', 'DL', 'city', 'Delhi'), now()),
    (NULL, 'page_view', 'web', jsonb_build_object('route', '/pricing', 'country', 'IN', 'region', 'DL', 'city', 'Delhi'), now());

  ------------------------------------------------------- b. role gate + rollup
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', outsider_id::text, 'email', 'p47-not-an-admin@example.com', 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.admin_web_analytics();
    RAISE EXCEPTION 'FAIL: a non-admin was able to call admin_web_analytics';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN RAISE EXCEPTION 'FAIL: non-admin admin_web_analytics raised "%", expected KITPAT_ADMIN_ONLY', err; END IF;
  END;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO row_count FROM public.admin_web_analytics();
  IF row_count < 2 THEN
    RAISE EXCEPTION 'FAIL: admin_web_analytics returned % grouped row(s) for an owner, expected at least 2 (Mumbai / and Delhi /pricing)', row_count;
  END IF;

  FOR in_row IN SELECT * FROM public.admin_web_analytics() LOOP
    IF in_row.country = 'IN' AND in_row.city = 'Mumbai' AND in_row.route = '/' THEN
      IF in_row.count <> 3 THEN
        RAISE EXCEPTION 'FAIL: expected count=3 for Mumbai/, got %', in_row.count;
      END IF;
      found_mumbai_home := true;
    ELSIF in_row.country = 'IN' AND in_row.city = 'Delhi' AND in_row.route = '/pricing' THEN
      IF in_row.count <> 2 THEN
        RAISE EXCEPTION 'FAIL: expected count=2 for Delhi/pricing, got %', in_row.count;
      END IF;
      found_delhi_pricing := true;
    END IF;
  END LOOP;
  IF NOT found_mumbai_home OR NOT found_delhi_pricing THEN
    RAISE EXCEPTION 'FAIL: admin_web_analytics did not return both expected grouped rows (mumbai_home=%, delhi_pricing=%)', found_mumbai_home, found_delhi_pricing;
  END IF;
  RAISE NOTICE 'PASS: admin_web_analytics raises KITPAT_ADMIN_ONLY for a non-admin and returns correctly grouped rows for an active admin';

  ------------------------------------------------------------- c. anon has nothing
  IF has_function_privilege('anon', 'public.admin_web_analytics(date, date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_web_analytics';
  END IF;
  IF has_table_privilege('anon', 'public.audit_events', 'SELECT')
     OR has_table_privilege('anon', 'public.audit_events', 'INSERT')
     OR has_table_privilege('anon', 'public.audit_events', 'UPDATE')
     OR has_table_privilege('anon', 'public.audit_events', 'DELETE') THEN
    RAISE EXCEPTION 'FAIL: anon holds some table-level privilege on audit_events';
  END IF;
  RAISE NOTICE 'PASS: anon holds no EXECUTE on admin_web_analytics and no privilege on audit_events';

  ------------------------------------------------------- d. deny-write policy intact
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', outsider_id::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  BEGIN
    INSERT INTO public.audit_events (event_name, source) VALUES ('page_view', 'web');
    RESET ROLE;
    RAISE EXCEPTION 'FAIL: a direct authenticated client INSERT into audit_events succeeded -- the deny policy is broken';
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    err := SQLERRM;
    IF err NOT LIKE '%row-level security%' AND err NOT LIKE '%policy%' THEN
      RAISE EXCEPTION 'FAIL: direct audit_events INSERT failed for an unexpected reason: %', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: audit_events still rejects a direct client write -- the deny-client-write policy is untouched';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
