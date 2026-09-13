-- AP14 test: payment gateway toggles, active_payment_gateways(),
-- admin_set_feature_flag(), and that the seeding is non-destructive to
-- whatever feature_flags rows already existed.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has this migration
-- (20260913010000_ap14_payment_toggles_and_flags.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap14_payment_toggles_and_flags_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. gateway_razorpay and gateway_payu exist, category 'payments', both
--      is_enabled false.
--   b. active_payment_gateways() returns nothing when both are off, the
--      right single key when one is on, and both when both are on.
--   c. The ON CONFLICT (key) DO NOTHING seeding mechanism is
--      non-destructive: re-running both INSERT statements from the
--      migration, verbatim, changes no existing row's is_enabled, label,
--      or description -- proven generically (by fingerprinting every
--      pre-test row, re-running the seed, and re-fingerprinting) rather
--      than by asserting specific historical values, since the 25
--      pre-existing rows were seeded outside migration history and this
--      test has no way to know their original values (confirmed: grepping
--      every migration for "INSERT INTO.*feature_flags" returns nothing).
--   d. admin_set_feature_flag raises KITPAT_ADMIN_ONLY for a non-admin and
--      KITPAT_INSUFFICIENT_ROLE for an active admin whose role is
--      'member' (the admin-domain code -- this IS an admin RPC, unlike
--      P44's member-facing record_contribution/record_expense).
--   e. A successful toggle writes an admin_audit row and flips is_enabled.
--   f. anon holds no EXECUTE on either new function.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap14-owner@kitpat.in';
  member_admin_email text := 'ap14-memberadmin@kitpat.in';
  outsider_id uuid;
  err text;
  gw_count integer;
  gw_key text;
  before_fingerprint text;
  after_fingerprint text;
  audit_count_before integer;
  audit_count_after integer;
  flag_row public.feature_flags;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES (owner_email, 'owner', true)
    ON CONFLICT (email) DO UPDATE SET role = 'owner', is_active = true;
  INSERT INTO public.admins (email, role, is_active) VALUES (member_admin_email, 'member', true)
    ON CONFLICT (email) DO UPDATE SET role = 'member', is_active = true;
  INSERT INTO public.users (name, phone, city) VALUES ('AP14 Outsider', '9922000099', 'Pune')
    RETURNING id INTO outsider_id;

  ------------------------------------------------------------- a. seeded shape
  IF NOT EXISTS (
    SELECT 1 FROM public.feature_flags
    WHERE key = 'gateway_razorpay' AND category = 'payments' AND is_enabled = false
  ) THEN
    RAISE EXCEPTION 'FAIL: gateway_razorpay is missing, mis-categorized, or not is_enabled=false';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.feature_flags
    WHERE key = 'gateway_payu' AND category = 'payments' AND is_enabled = false
  ) THEN
    RAISE EXCEPTION 'FAIL: gateway_payu is missing, mis-categorized, or not is_enabled=false';
  END IF;
  RAISE NOTICE 'PASS: gateway_razorpay and gateway_payu exist, category payments, both is_enabled false';

  ------------------------------------------------- b. active_payment_gateways()
  SELECT count(*) INTO gw_count FROM public.active_payment_gateways();
  IF gw_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: active_payment_gateways() returned % rows with both gateways off, expected 0', gw_count;
  END IF;

  UPDATE public.feature_flags SET is_enabled = true WHERE key = 'gateway_razorpay';
  SELECT count(*), max(key) INTO gw_count, gw_key FROM public.active_payment_gateways() AS key;
  IF gw_count <> 1 OR gw_key <> 'razorpay' THEN
    RAISE EXCEPTION 'FAIL: with only razorpay on, expected exactly [''razorpay''], got count=% key=%', gw_count, gw_key;
  END IF;

  UPDATE public.feature_flags SET is_enabled = true WHERE key = 'gateway_payu';
  SELECT count(*) INTO gw_count FROM public.active_payment_gateways();
  IF gw_count <> 2 THEN
    RAISE EXCEPTION 'FAIL: with both gateways on, expected 2 rows, got %', gw_count;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.active_payment_gateways() AS key WHERE key = 'razorpay')
     OR NOT EXISTS (SELECT 1 FROM public.active_payment_gateways() AS key WHERE key = 'payu') THEN
    RAISE EXCEPTION 'FAIL: with both gateways on, expected both ''razorpay'' and ''payu'' present';
  END IF;
  RAISE NOTICE 'PASS: active_payment_gateways() returns nothing when both off, the right single key when one is on, and both when both are on';

  UPDATE public.feature_flags SET is_enabled = false WHERE key IN ('gateway_razorpay', 'gateway_payu');

  ------------------------------------------------- c. seeding is non-destructive
  SELECT string_agg(key || ':' || is_enabled::text || ':' || coalesce(label,'') || ':' || coalesce(description,''), '|' ORDER BY key)
  INTO before_fingerprint
  FROM public.feature_flags;

  INSERT INTO public.feature_flags (key, label, description, is_enabled, category)
  VALUES
    ('gateway_razorpay', 'Razorpay payments', 'Lets members pay for a plan using Razorpay (cards, UPI, netbanking, wallets). Turn this on once Razorpay is ready to accept live payments.', false, 'payments'),
    ('gateway_payu', 'PayU payments', 'Lets members pay for a plan using PayU (cards, UPI, netbanking, wallets). Turn this on once PayU is ready to accept live payments.', false, 'payments')
  ON CONFLICT (key) DO NOTHING;

  INSERT INTO public.feature_flags (key, label, description, is_enabled, category)
  VALUES
    ('food_tracking', 'Food tracking', 'Lets members log what they ate, either by typing a description or from a photo.', true, 'features'),
    ('food_image_input', 'Food logging from a photo', 'Lets members snap a photo of their food instead of typing a description; an AI provider identifies the dish.', true, 'features'),
    ('memories', 'Memories', 'Lets members save and share photos/moments tied to a group, so a party''s highlights stay in one place.', true, 'features'),
    ('kitty_ledger', 'Kitty ledger', 'The shared money pool for a group: contributions in, expenses out, with a running balance everyone can see.', true, 'features'),
    ('group_invites', 'Group invites', 'Lets a host invite new people into a group via a shareable link or code.', true, 'features'),
    ('party_recap', 'Party recap', 'Shows a summary of a group''s event afterwards -- who came, what was spent, highlights from the ledger and memories.', true, 'features'),
    ('emoji_guess', 'Emoji Guess game', 'A party game where players guess a word or phrase from a string of emoji.', true, 'games'),
    ('rapid_fire', 'Rapid Fire game', 'A fast-paced quiz-style party game with quick-answer rounds.', true, 'games'),
    ('who_knows_who', 'Who Knows Who game', 'A party game that tests how well the group knows each other.', true, 'games'),
    ('spin_dare', 'Spin & Dare game', 'A spin-the-wheel style dare game for the group to play together.', true, 'games'),
    ('pass_the_parcel', 'Pass the Parcel game', 'A digital take on the classic pass-the-parcel party game.', true, 'games'),
    ('email_verification', 'Email verification', 'Lets a member add and verify an email address on their account.', true, 'auth'),
    ('phone_change', 'Phone number change', 'Lets a member change the phone number linked to their account, with OTP verification.', true, 'auth')
  ON CONFLICT (key) DO NOTHING;

  SELECT string_agg(key || ':' || is_enabled::text || ':' || coalesce(label,'') || ':' || coalesce(description,''), '|' ORDER BY key)
  INTO after_fingerprint
  FROM public.feature_flags;

  IF before_fingerprint <> after_fingerprint THEN
    RAISE EXCEPTION 'FAIL: re-running the migration''s seed INSERTs changed at least one existing feature_flags row -- ON CONFLICT (key) DO NOTHING did not protect it';
  END IF;
  RAISE NOTICE 'PASS: re-running both seed INSERT statements verbatim changes no existing row (key, is_enabled, label, description all identical) -- ON CONFLICT (key) DO NOTHING protects every pre-existing row, including the 25 seeded outside migration history';

  ------------------------------------------------- d. admin_set_feature_flag role gate
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', outsider_id::text, 'email', 'ap14-not-an-admin@example.com', 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.admin_set_feature_flag('gateway_razorpay', true);
    RAISE EXCEPTION 'FAIL: a non-admin was able to call admin_set_feature_flag';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_set_feature_flag raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: admin_set_feature_flag raises KITPAT_ADMIN_ONLY for a non-admin';

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', member_admin_email, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.admin_set_feature_flag('gateway_razorpay', true);
    RAISE EXCEPTION 'FAIL: a member-role admin was able to call admin_set_feature_flag';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN
      RAISE EXCEPTION 'FAIL: member-admin admin_set_feature_flag raised "%", expected KITPAT_INSUFFICIENT_ROLE', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: admin_set_feature_flag raises KITPAT_INSUFFICIENT_ROLE for an active admin whose role is member';

  ------------------------------------------------- e. successful toggle + audit
  SELECT count(*) INTO audit_count_before FROM public.admin_audit;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  flag_row := public.admin_set_feature_flag('gateway_razorpay', true);
  IF flag_row.key <> 'gateway_razorpay' OR flag_row.is_enabled <> true THEN
    RAISE EXCEPTION 'FAIL: admin_set_feature_flag did not return the updated row: %', flag_row;
  END IF;

  SELECT is_enabled INTO flag_row.is_enabled FROM public.feature_flags WHERE key = 'gateway_razorpay';
  IF flag_row.is_enabled <> true THEN
    RAISE EXCEPTION 'FAIL: gateway_razorpay.is_enabled was not persisted as true';
  END IF;

  SELECT count(*) INTO audit_count_after FROM public.admin_audit;
  IF audit_count_after <> audit_count_before + 1 THEN
    RAISE EXCEPTION 'FAIL: a successful admin_set_feature_flag call did not write exactly one admin_audit row (before=%, after=%)', audit_count_before, audit_count_after;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_audit
    WHERE action = 'set:feature_flag' AND target_type = 'feature_flags' AND target_id = 'gateway_razorpay'
      AND actor_email = owner_email
    ORDER BY created_at DESC LIMIT 1
  ) THEN
    RAISE EXCEPTION 'FAIL: the admin_audit row for the successful toggle does not have the expected action/target_type/target_id/actor_email';
  END IF;
  RAISE NOTICE 'PASS: a successful toggle flips is_enabled, returns the updated row, and writes exactly one admin_audit row attributed to the calling owner';

  ------------------------------------------------------------- f. anon has no EXECUTE
  IF has_function_privilege('anon', 'public.active_payment_gateways()', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on active_payment_gateways()';
  END IF;
  IF has_function_privilege('anon', 'public.admin_set_feature_flag(text, boolean)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on admin_set_feature_flag(text, boolean)';
  END IF;
  RAISE NOTICE 'PASS: anon holds no EXECUTE on active_payment_gateways() or admin_set_feature_flag()';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
