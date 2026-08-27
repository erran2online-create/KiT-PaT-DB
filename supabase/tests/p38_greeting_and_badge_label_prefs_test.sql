-- P38 test: greeting preference / rotation + badge label gender preference.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P38 migration
-- (20260828040000_p38_greeting_and_badge_label_prefs.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p38_greeting_and_badge_label_prefs_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. greeting_variants has all 16 seeded phrases.
--   2. get_daily_greeting() returns one of the active phrases when the
--      caller has no greeting_pref set, and is deterministic (same call
--      twice in the same day returns the same phrase).
--   3. Setting users.greeting_pref pins get_daily_greeting() to that exact
--      value, even a value outside the greeting_variants catalogue.
--   4. users.badge_label_pref accepts 'neutral' / 'female' / 'male' and
--      rejects any other value with a check_violation.
--   5. Direct writes to greeting_variants as `authenticated` are rejected
--      (read-only catalogue; only service_role can write).

BEGIN;

DO $t$
DECLARE
  u_id uuid := gen_random_uuid();
  seeded_count integer;
  active_phrases text[];
  greeting_1 text;
  greeting_2 text;
  pinned_value text;
  write_blocked boolean;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (id, name, phone) VALUES
    (u_id, 'P38 Test User', '+910000000970');

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_id::text, 'role', 'authenticated')::text, true);

  ------------------------------------------------------- 1. seeded catalogue
  SELECT count(*) INTO seeded_count FROM public.greeting_variants;
  IF seeded_count <> 16 THEN
    RAISE EXCEPTION 'FAIL: greeting_variants has % rows, expected 16', seeded_count;
  END IF;
  RAISE NOTICE 'PASS: greeting_variants has all 16 seeded phrases';

  --------------------------------------------------- 2. rotation, unpinned
  SELECT array_agg(phrase) INTO active_phrases FROM public.greeting_variants WHERE is_active;

  greeting_1 := public.get_daily_greeting();
  IF greeting_1 IS NULL OR NOT (greeting_1 = ANY (active_phrases)) THEN
    RAISE EXCEPTION 'FAIL: get_daily_greeting() returned %, not one of the active greeting_variants phrases', greeting_1;
  END IF;

  greeting_2 := public.get_daily_greeting();
  IF greeting_2 <> greeting_1 THEN
    RAISE EXCEPTION 'FAIL: get_daily_greeting() returned % then %, expected the same deterministic phrase on repeat calls the same day', greeting_1, greeting_2;
  END IF;
  RAISE NOTICE 'PASS: get_daily_greeting() returns an active phrase and is deterministic for repeat calls on the same day';

  ------------------------------------------------------------- 3. pinning
  UPDATE public.users SET greeting_pref = 'your chai club' WHERE id = u_id;
  pinned_value := public.get_daily_greeting();
  IF pinned_value <> 'your chai club' THEN
    RAISE EXCEPTION 'FAIL: get_daily_greeting() returned % after pinning, expected ''your chai club''', pinned_value;
  END IF;

  -- A pin need not be one of the catalogue phrases -- it's returned verbatim.
  UPDATE public.users SET greeting_pref = 'your absolutely one-of-a-kind lot' WHERE id = u_id;
  pinned_value := public.get_daily_greeting();
  IF pinned_value <> 'your absolutely one-of-a-kind lot' THEN
    RAISE EXCEPTION 'FAIL: get_daily_greeting() returned %, expected the pinned value verbatim', pinned_value;
  END IF;

  UPDATE public.users SET greeting_pref = NULL WHERE id = u_id;
  RAISE NOTICE 'PASS: setting users.greeting_pref pins get_daily_greeting() to that exact value';

  --------------------------------------------------- 4. badge_label_pref CHECK
  BEGIN
    UPDATE public.users SET badge_label_pref = 'nonbinary' WHERE id = u_id;
    RAISE EXCEPTION 'FAIL: badge_label_pref accepted an invalid value (''nonbinary'')';
  EXCEPTION WHEN check_violation THEN
    NULL; -- expected
  END;

  UPDATE public.users SET badge_label_pref = 'neutral' WHERE id = u_id;
  UPDATE public.users SET badge_label_pref = 'female' WHERE id = u_id;
  UPDATE public.users SET badge_label_pref = 'male' WHERE id = u_id;
  IF (SELECT badge_label_pref FROM public.users WHERE id = u_id) <> 'male' THEN
    RAISE EXCEPTION 'FAIL: badge_label_pref did not persist a valid value';
  END IF;
  RAISE NOTICE 'PASS: users.badge_label_pref accepts neutral/female/male and rejects any other value';

  --------------------------------------------- 5. catalogue is read-only
  SET LOCAL ROLE authenticated;
  BEGIN
    INSERT INTO public.greeting_variants (phrase) VALUES ('hacked');
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;

  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: INSERT into greeting_variants as authenticated was not rejected with insufficient_privilege';
  END IF;
  RAISE NOTICE 'PASS: direct writes to greeting_variants as authenticated are rejected -- only service_role can write';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
