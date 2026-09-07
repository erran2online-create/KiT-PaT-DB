-- AP5 test: app_content seed shape, the UNIQUE(key, locale) constraint,
-- public read access to published (only) rows, get_app_content's locale
-- fallback, direct-write rejection, and admin_can_write's role rule.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0 and this migration
-- (20260908010000_ap5_app_content.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap5_app_content_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. app_content has the 6 legal, 8 app and 8 website seeded rows.
--   2. UNIQUE (key, locale) rejects a duplicate.
--   3. An anon caller CAN read a published legal row (required for store
--      review) and CANNOT read an unpublished one.
--   4. get_app_content falls back to the en-IN row for a locale with no
--      row of its own.
--   5. A direct client INSERT/UPDATE fails (authenticated and anon).
--   6. admin_can_write is true for owner and org_admin on app_content,
--      false for member.

BEGIN;

DO $t$
DECLARE
  legal_count integer;
  app_count integer;
  website_count integer;
  total_count integer;
  unpublished_id uuid;
  visible_count integer;
  fallback_body text;
  en_body text;
  write_blocked boolean;
  owner_email text := 'ap5.owner.test@kitpat.in';
  org_admin_email text := 'ap5.orgadmin.test@kitpat.in';
  member_email text := 'ap5.member.test@kitpat.in';
BEGIN
  ------------------------------------------------------------ 1. seed shape
  SELECT count(*) INTO legal_count FROM public.app_content WHERE surface = 'legal';
  SELECT count(*) INTO app_count FROM public.app_content WHERE surface = 'app';
  SELECT count(*) INTO website_count FROM public.app_content WHERE surface = 'website';
  SELECT count(*) INTO total_count FROM public.app_content;

  IF legal_count <> 6 THEN
    RAISE EXCEPTION 'FAIL: % legal rows seeded, expected 6', legal_count;
  END IF;
  IF app_count <> 8 THEN
    RAISE EXCEPTION 'FAIL: % app rows seeded, expected 8', app_count;
  END IF;
  IF website_count <> 8 THEN
    RAISE EXCEPTION 'FAIL: % website rows seeded, expected 8', website_count;
  END IF;
  IF total_count <> 22 THEN
    RAISE EXCEPTION 'FAIL: % total app_content rows, expected 22', total_count;
  END IF;
  RAISE NOTICE 'PASS: app_content has the 6 legal, 8 app and 8 website seeded rows';

  ------------------------------------------------------------ 2. UNIQUE constraint
  BEGIN
    INSERT INTO public.app_content (key, locale, surface, title, body)
    VALUES ('privacy_policy', 'en-IN', 'legal', 'Dup', 'Dup');
    RAISE EXCEPTION 'FAIL: app_content accepted a duplicate (key, locale) row';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
  RAISE NOTICE 'PASS: UNIQUE (key, locale) rejects a duplicate';

  ------------------------------------------------------ 3. anon read (published only)
  INSERT INTO public.app_content (key, locale, surface, title, body, is_published)
  VALUES ('ap5_test_unpublished', 'en-IN', 'app', 'Hidden', 'Should not be readable', false)
  RETURNING id INTO unpublished_id;

  SET LOCAL ROLE anon;
  SELECT count(*) INTO visible_count FROM public.app_content WHERE key = 'privacy_policy' AND locale = 'en-IN';
  RESET ROLE;
  IF visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: anon could not read the published privacy_policy row (count=%)', visible_count;
  END IF;

  SET LOCAL ROLE anon;
  SELECT count(*) INTO visible_count FROM public.app_content WHERE id = unpublished_id;
  RESET ROLE;
  IF visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: anon could read an unpublished app_content row (count=%), expected 0', visible_count;
  END IF;
  RAISE NOTICE 'PASS: anon can read a published legal row and cannot read an unpublished one';

  --------------------------------------------------- 4. get_app_content fallback
  SELECT body INTO en_body FROM public.app_content WHERE key = 'privacy_policy' AND locale = 'en-IN';

  SELECT body INTO fallback_body FROM public.get_app_content('legal', 'fr-FR') WHERE key = 'privacy_policy';
  IF fallback_body IS NULL OR fallback_body <> en_body THEN
    RAISE EXCEPTION 'FAIL: get_app_content(legal, fr-FR) returned body=%, expected the en-IN fallback body=%', fallback_body, en_body;
  END IF;
  RAISE NOTICE 'PASS: get_app_content falls back to the en-IN row for a locale with no row of its own';

  ------------------------------------------------------------ 5. direct writes blocked
  SET LOCAL ROLE authenticated;
  BEGIN
    INSERT INTO public.app_content (key, locale, surface, title, body) VALUES ('forged', 'en-IN', 'app', 'Forged', 'Forged');
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: direct INSERT into app_content as authenticated was not rejected';
  END IF;

  SET LOCAL ROLE anon;
  BEGIN
    INSERT INTO public.app_content (key, locale, surface, title, body) VALUES ('forged', 'en-IN', 'app', 'Forged', 'Forged');
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: direct INSERT into app_content as anon was not rejected';
  END IF;

  SET LOCAL ROLE authenticated;
  BEGIN
    UPDATE public.app_content SET body = 'Forged' WHERE key = 'privacy_policy' AND locale = 'en-IN';
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: direct UPDATE on app_content as authenticated was not rejected';
  END IF;
  RAISE NOTICE 'PASS: direct client INSERT/UPDATE on app_content fails (authenticated and anon)';

  ------------------------------------------------------- 6. admin_can_write role rule
  INSERT INTO public.admins (email, role, is_active) VALUES
    (owner_email, 'owner', true),
    (org_admin_email, 'org_admin', true),
    (member_email, 'member', true)
  ON CONFLICT (email) DO UPDATE SET role = EXCLUDED.role, is_active = true;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  IF NOT public.admin_can_write('app_content') THEN
    RAISE EXCEPTION 'FAIL: admin_can_write(app_content) = false for owner, expected true';
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', org_admin_email, 'role', 'authenticated')::text, true);
  IF NOT public.admin_can_write('app_content') THEN
    RAISE EXCEPTION 'FAIL: admin_can_write(app_content) = false for org_admin, expected true';
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', member_email, 'role', 'authenticated')::text, true);
  IF public.admin_can_write('app_content') THEN
    RAISE EXCEPTION 'FAIL: admin_can_write(app_content) = true for member, expected false';
  END IF;
  RAISE NOTICE 'PASS: admin_can_write(app_content) is true for owner and org_admin, false for member';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
