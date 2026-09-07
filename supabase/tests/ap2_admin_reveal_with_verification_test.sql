-- AP2 test: owner-only, double-verified reveal of a user's real
-- phone/email.
--
-- SQL side only. The admin-reveal edge function's email delivery and
-- password (signInWithPassword) round trip are NOT SQL-testable and are
-- NOT exercised or asserted anywhere in this file -- stated plainly
-- rather than claiming they were tested.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0, AP1, and this migration
-- (20260907030000_ap2_admin_reveal_with_verification.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap2_admin_reveal_with_verification_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. admin_list_users returns masked values only -- never a raw
--      phone/email -- for an owner, and raises KITPAT_ADMIN_ONLY for a
--      non-admin.
--   2. admin_request_reveal raises KITPAT_INSUFFICIENT_ROLE for org_admin
--      and member.
--   3. A created reveal request stores a HASHED code (not equal to the
--      plaintext) with a 5-minute expiry.
--   4. admin_confirm_reveal with a wrong code increments attempt_count and
--      raises KITPAT_REVEAL_CODE_INVALID; after max_attempts it raises
--      KITPAT_REVEAL_LOCKED; an expired request raises
--      KITPAT_REVEAL_CODE_EXPIRED.
--   5. A successful confirm writes an admin_audit row with
--      is_sensitive_reveal = true, and returns the correct value.
--   6. admin_reveal_requests rejects direct client access entirely.

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap2.owner.test@kitpat.in';
  org_admin_email text := 'ap2.orgadmin.test@kitpat.in';
  member_email text := 'ap2.member.test@kitpat.in';
  target_user_id uuid;
  users_before integer;
  row_rec record;
  err text;
  req_json jsonb;
  req_id uuid;
  plaintext_code text;
  code_hash_stored text;
  confirm_result jsonb;
  audit_count integer;
  audit_count_after integer;
  write_blocked boolean;
  i integer;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES
    (owner_email, 'owner', true),
    (org_admin_email, 'org_admin', true),
    (member_email, 'member', true)
  ON CONFLICT (email) DO UPDATE SET role = EXCLUDED.role, is_active = true;

  INSERT INTO public.users (name, phone, email, city)
  VALUES ('AP2 Target User', '9876543210', 'target@realmail.com', 'Mumbai')
  RETURNING id INTO target_user_id;

  ------------------------------------------------------- 1. admin_list_users
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);

  SELECT * INTO row_rec FROM public.admin_list_users(NULL, 50, 0) WHERE id = target_user_id;
  IF row_rec.id IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_list_users did not return the fixture user for an owner';
  END IF;
  IF row_rec.masked_phone = '9876543210' OR row_rec.masked_phone !~ '^\+91X+\d{2}$' THEN
    RAISE EXCEPTION 'FAIL: admin_list_users masked_phone = %, expected a masked +91X...NN value, never the raw phone', row_rec.masked_phone;
  END IF;
  IF row_rec.masked_email = 'target@realmail.com' OR row_rec.masked_email !~ '^x+@realmail\.com$' THEN
    RAISE EXCEPTION 'FAIL: admin_list_users masked_email = %, expected a masked x...@realmail.com value, never the raw email', row_rec.masked_email;
  END IF;
  RAISE NOTICE 'PASS: admin_list_users returns masked_phone/masked_email only for an owner, never the raw values';

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', 'not-an-admin@example.com', 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM * FROM public.admin_list_users(NULL, 50, 0);
    RAISE EXCEPTION 'FAIL: admin_list_users succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_list_users call raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: admin_list_users raises KITPAT_ADMIN_ONLY for a non-admin';

  --------------------------------------------------- 2. request_reveal role gate
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', org_admin_email, 'role', 'authenticated')::text, true);
  BEGIN
    req_json := public.admin_request_reveal(target_user_id, 'phone');
    RAISE EXCEPTION 'FAIL: admin_request_reveal succeeded for an org_admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN
      RAISE EXCEPTION 'FAIL: org_admin admin_request_reveal raised "%", expected KITPAT_INSUFFICIENT_ROLE', err;
    END IF;
  END;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', member_email, 'role', 'authenticated')::text, true);
  BEGIN
    req_json := public.admin_request_reveal(target_user_id, 'phone');
    RAISE EXCEPTION 'FAIL: admin_request_reveal succeeded for a member';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN
      RAISE EXCEPTION 'FAIL: member admin_request_reveal raised "%", expected KITPAT_INSUFFICIENT_ROLE', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: admin_request_reveal raises KITPAT_INSUFFICIENT_ROLE for org_admin and member';

  ------------------------------------------------------- 3. request stores a hash
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', owner_email, 'role', 'authenticated')::text, true);
  req_json := public.admin_request_reveal(target_user_id, 'phone');
  req_id := (req_json ->> 'request_id')::uuid;
  plaintext_code := req_json ->> 'code';

  IF req_id IS NULL OR plaintext_code !~ '^\d{6}$' THEN
    RAISE EXCEPTION 'FAIL: admin_request_reveal returned request_id=%, code=%, expected a uuid and a 6-digit code', req_id, plaintext_code;
  END IF;
  IF (req_json ->> 'expires_in')::integer NOT BETWEEN 290 AND 300 THEN
    RAISE EXCEPTION 'FAIL: admin_request_reveal expires_in = %, expected ~300 (5 minutes)', req_json ->> 'expires_in';
  END IF;

  SELECT code_hash, expires_at INTO row_rec FROM public.admin_reveal_requests WHERE id = req_id;
  code_hash_stored := row_rec.code_hash;
  IF code_hash_stored IS NULL OR code_hash_stored = plaintext_code THEN
    RAISE EXCEPTION 'FAIL: admin_reveal_requests.code_hash = %, expected a salted hash distinct from the plaintext code %', code_hash_stored, plaintext_code;
  END IF;
  IF row_rec.expires_at < now() + interval '4 minutes' OR row_rec.expires_at > now() + interval '6 minutes' THEN
    RAISE EXCEPTION 'FAIL: admin_reveal_requests.expires_at = %, expected ~5 minutes from now', row_rec.expires_at;
  END IF;
  RAISE NOTICE 'PASS: a created reveal request stores a hashed code (not the plaintext) with a ~5-minute expiry';

  --------------------------------------------------------- 4a. wrong code
  BEGIN
    confirm_result := public.admin_confirm_reveal(req_id, '000000');
    IF (plaintext_code = '000000') THEN
      RAISE EXCEPTION 'FAIL: test fixture collided with the real code, retry';
    END IF;
    RAISE EXCEPTION 'FAIL: admin_confirm_reveal succeeded with a wrong code';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_REVEAL_CODE_INVALID' THEN
      RAISE EXCEPTION 'FAIL: wrong-code admin_confirm_reveal raised "%", expected KITPAT_REVEAL_CODE_INVALID', err;
    END IF;
  END;

  SELECT attempt_count INTO row_rec FROM public.admin_reveal_requests WHERE id = req_id;
  IF row_rec.attempt_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: attempt_count = % after one wrong code, expected 1', row_rec.attempt_count;
  END IF;
  RAISE NOTICE 'PASS: a wrong code increments attempt_count and raises KITPAT_REVEAL_CODE_INVALID';

  ------------------------------------------------------- 4b. lock after max_attempts
  FOR i IN 1..2 LOOP -- two more wrong attempts brings attempt_count to 3 = max_attempts
    BEGIN
      confirm_result := public.admin_confirm_reveal(req_id, '000001');
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
  END LOOP;

  BEGIN
    confirm_result := public.admin_confirm_reveal(req_id, plaintext_code); -- even the real code, now locked out
    RAISE EXCEPTION 'FAIL: admin_confirm_reveal succeeded after max_attempts was reached';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_REVEAL_LOCKED' THEN
      RAISE EXCEPTION 'FAIL: post-lockout admin_confirm_reveal raised "%", expected KITPAT_REVEAL_LOCKED', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: after max_attempts wrong codes, admin_confirm_reveal raises KITPAT_REVEAL_LOCKED even for the correct code';

  --------------------------------------------------------- 4c. expired request
  req_json := public.admin_request_reveal(target_user_id, 'phone');
  req_id := (req_json ->> 'request_id')::uuid;
  plaintext_code := req_json ->> 'code';
  UPDATE public.admin_reveal_requests SET expires_at = now() - interval '1 second' WHERE id = req_id;

  BEGIN
    confirm_result := public.admin_confirm_reveal(req_id, plaintext_code);
    RAISE EXCEPTION 'FAIL: admin_confirm_reveal succeeded against an expired request';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_REVEAL_CODE_EXPIRED' THEN
      RAISE EXCEPTION 'FAIL: expired admin_confirm_reveal raised "%", expected KITPAT_REVEAL_CODE_EXPIRED', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: an expired request raises KITPAT_REVEAL_CODE_EXPIRED';

  ------------------------------------------------ 5. successful confirm + audit
  req_json := public.admin_request_reveal(target_user_id, 'phone');
  req_id := (req_json ->> 'request_id')::uuid;
  plaintext_code := req_json ->> 'code';

  SELECT count(*) INTO audit_count FROM public.admin_audit WHERE is_sensitive_reveal = true AND revealed_subject = target_user_id::text;

  confirm_result := public.admin_confirm_reveal(req_id, plaintext_code);
  IF (confirm_result ->> 'field') <> 'phone' OR (confirm_result ->> 'value') <> '9876543210' THEN
    RAISE EXCEPTION 'FAIL: admin_confirm_reveal returned %, expected field=phone, value=9876543210', confirm_result;
  END IF;

  SELECT count(*) INTO audit_count_after FROM public.admin_audit
  WHERE is_sensitive_reveal = true AND revealed_subject = target_user_id::text AND revealed_field = 'phone';
  IF audit_count_after <= audit_count THEN
    RAISE EXCEPTION 'FAIL: a successful confirm did not add a new is_sensitive_reveal admin_audit row';
  END IF;
  RAISE NOTICE 'PASS: a successful confirm returns the correct real value and writes an is_sensitive_reveal=true admin_audit row';

  ------------------------------------------------- 6. table is client-inaccessible
  SET LOCAL ROLE authenticated;
  BEGIN
    PERFORM 1 FROM public.admin_reveal_requests LIMIT 1;
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: authenticated could read public.admin_reveal_requests directly';
  END IF;

  SET LOCAL ROLE anon;
  BEGIN
    PERFORM 1 FROM public.admin_reveal_requests LIMIT 1;
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: anon could read public.admin_reveal_requests directly';
  END IF;
  RAISE NOTICE 'PASS: admin_reveal_requests rejects direct client access (authenticated and anon) entirely';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
  RAISE NOTICE 'NOTE: the admin-reveal edge function''s email delivery and password (signInWithPassword) round trip were NOT tested here -- not SQL-testable.';
END;
$t$;

ROLLBACK;
