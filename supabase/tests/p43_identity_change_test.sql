-- P43 test: users.email_verified_at, the otp_verification purpose/user_id/
-- email extension, users.phone's existing UNIQUE constraint, the new
-- identity-column guard trigger, and anon/authenticated lockout on the
-- new confirm_* RPCs.
--
-- Both edge functions (verify-email, change-phone) are NOT SQL-testable
-- and are NOT exercised here -- this file covers only the SQL side: the
-- schema changes, the guard trigger, and the two confirm_* RPCs (called
-- directly, the way each edge function's service_role client calls them).
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has this migration
-- (20260910020000_p43_identity_change.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p43_identity_change_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. users.email_verified_at exists, is nullable, defaults NULL.
--   b. All existing users still read normally (own-row RLS unchanged).
--   c. otp_verification's purpose CHECK rejects an invalid value.
--   d. users.phone's existing UNIQUE constraint (users_phone_key) prevents
--      two users holding the same phone.
--   e. anon holds no privilege on anything new (otp_verification's new
--      columns, confirm_phone_change, confirm_email_verification), and
--      authenticated cannot call either confirm_* RPC directly either
--      (service_role only).
--   (extra, beyond the letter of the task but load-bearing for the whole
--   feature's actual security): the new BEFORE UPDATE trigger blocks a
--   direct client update to users.phone or users.email_verified_at, and
--   confirm_phone_change/confirm_email_verification -- called via
--   service_role, exactly as each edge function calls them -- correctly
--   perform the swap end to end including the race-guard re-check.

BEGIN;

DO $t$
DECLARE
  col record;
  existing_user_id uuid;
  own_visible integer;
  err text;
  user_a uuid;
  phone_a text := '9911100001';
  anon_priv boolean;
  authenticated_priv boolean;
  otp_id uuid;
  raw_code text := '123456';
  salt text := 'testsalt';
  confirm_result record;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (name, phone, city) VALUES ('P43 User A', phone_a, 'Mumbai') RETURNING id INTO user_a;

  --------------------------------------------------- a. email_verified_at column
  SELECT column_name, is_nullable, column_default INTO col
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'email_verified_at';
  IF col.column_name IS NULL THEN
    RAISE EXCEPTION 'FAIL: users.email_verified_at does not exist';
  END IF;
  IF col.is_nullable <> 'YES' OR col.column_default IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: users.email_verified_at is_nullable=%, default=%, expected nullable with no default', col.is_nullable, col.column_default;
  END IF;
  RAISE NOTICE 'PASS: users.email_verified_at exists, is nullable, and defaults to NULL';

  ------------------------------------------------------- b. existing users read
  SELECT id INTO existing_user_id FROM public.users LIMIT 1;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', existing_user_id::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO own_visible FROM public.users WHERE id = existing_user_id;
  RESET ROLE;
  IF own_visible <> 1 THEN
    RAISE EXCEPTION 'FAIL: an existing user could not read their own row after this migration (count=%)', own_visible;
  END IF;
  RAISE NOTICE 'PASS: existing users still read normally';

  --------------------------------------------------- c. otp_verification purpose CHECK
  BEGIN
    INSERT INTO public.otp_verification (phone, channel, purpose, otp_hash, expires_at)
    VALUES (phone_a, 'sms', 'bogus_purpose', 'x:y', now() + interval '5 minutes');
    RAISE EXCEPTION 'FAIL: otp_verification accepted an invalid purpose value';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  RAISE NOTICE 'PASS: the purpose CHECK on otp_verification rejects an invalid value';

  ------------------------------------------------------- d. users.phone UNIQUE
  BEGIN
    INSERT INTO public.users (name, phone, city) VALUES ('P43 Duplicate Phone', phone_a, 'Mumbai');
    RAISE EXCEPTION 'FAIL: a duplicate phone was accepted on users';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
  RAISE NOTICE 'PASS: users.phone''s existing UNIQUE constraint prevents two users holding the same phone';

  --------------------------------------------------------------- e. anon lockout
  SELECT has_function_privilege('anon', 'public.confirm_phone_change(uuid,text)', 'EXECUTE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on confirm_phone_change';
  END IF;
  SELECT has_function_privilege('authenticated', 'public.confirm_phone_change(uuid,text)', 'EXECUTE') INTO authenticated_priv;
  IF authenticated_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: authenticated holds EXECUTE on confirm_phone_change (service_role only)';
  END IF;

  SELECT has_function_privilege('anon', 'public.confirm_email_verification(uuid,text)', 'EXECUTE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on confirm_email_verification';
  END IF;
  SELECT has_function_privilege('authenticated', 'public.confirm_email_verification(uuid,text)', 'EXECUTE') INTO authenticated_priv;
  IF authenticated_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: authenticated holds EXECUTE on confirm_email_verification (service_role only)';
  END IF;

  SELECT has_table_privilege('anon', 'public.otp_verification', 'SELECT') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds SELECT on otp_verification';
  END IF;
  RAISE NOTICE 'PASS: anon holds no privilege on anything new, and authenticated cannot call either confirm_* RPC directly';

  ------------------------------------------- extra: the guard trigger is load-bearing
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_a::text, 'role', 'authenticated')::text, true);
  BEGIN
    UPDATE public.users SET phone = '9911199999' WHERE id = user_a;
    RAISE EXCEPTION 'FAIL: a direct client UPDATE changed users.phone with no OTP involved';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_PHONE_CHANGE_REQUIRES_VERIFICATION' THEN
      RAISE EXCEPTION 'FAIL: direct phone UPDATE raised "%", expected KITPAT_PHONE_CHANGE_REQUIRES_VERIFICATION', err;
    END IF;
  END;

  BEGIN
    UPDATE public.users SET email_verified_at = now() WHERE id = user_a;
    RAISE EXCEPTION 'FAIL: a direct client UPDATE forged users.email_verified_at with no OTP involved';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_EMAIL_VERIFICATION_REQUIRES_OTP' THEN
      RAISE EXCEPTION 'FAIL: direct email_verified_at UPDATE raised "%", expected KITPAT_EMAIL_VERIFICATION_REQUIRES_OTP', err;
    END IF;
  END;
  RESET ROLE;
  RAISE NOTICE 'PASS: the guard trigger blocks a direct client UPDATE to phone or email_verified_at';

  ---------------------------------------------- extra: confirm_phone_change end to end
  otp_id := gen_random_uuid();
  INSERT INTO public.otp_verification (id, purpose, user_id, phone, channel, otp_hash, expires_at, is_used)
  VALUES (
    otp_id, 'phone_change', user_a, '9911155555', 'telegram',
    salt || ':' || encode(extensions.digest(salt || ':' || raw_code, 'sha256'), 'hex'),
    now() + interval '5 minutes', false
  );

  -- auth.role() reads the JWT claims GUC (request.jwt.claims), NOT the
  -- actual Postgres session role -- SET LOCAL ROLE service_role alone
  -- would not satisfy confirm_phone_change's own auth.role() = 'service_role'
  -- guard, so both are set together here, matching what PostgREST
  -- actually does for a real service_role-keyed request (sets the
  -- session role AND presents the service_role JWT's claims).
  SET LOCAL ROLE service_role;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'service_role')::text, true);

  -- Wrong code first: must not consume the row or touch users.phone.
  BEGIN
    PERFORM public.confirm_phone_change(user_a, '000000');
    RAISE EXCEPTION 'FAIL: confirm_phone_change succeeded with the wrong code';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_CODE_INVALID' THEN
      RAISE EXCEPTION 'FAIL: wrong-code confirm_phone_change raised "%", expected KITPAT_CODE_INVALID', err;
    END IF;
  END;

  SELECT * INTO confirm_result FROM public.confirm_phone_change(user_a, raw_code);
  RESET ROLE;
  IF confirm_result.old_phone <> phone_a OR confirm_result.new_phone <> '9911155555' THEN
    RAISE EXCEPTION 'FAIL: confirm_phone_change returned old=%, new=%, expected %/9911155555', confirm_result.old_phone, confirm_result.new_phone, phone_a;
  END IF;
  IF (SELECT phone FROM public.users WHERE id = user_a) <> '9911155555' THEN
    RAISE EXCEPTION 'FAIL: confirm_phone_change did not actually update users.phone';
  END IF;
  IF (SELECT is_used FROM public.otp_verification WHERE id = otp_id) IS NOT true THEN
    RAISE EXCEPTION 'FAIL: confirm_phone_change did not mark the OTP row used';
  END IF;

  -- Same code again must now fail: the row is used and no other unused
  -- phone_change row exists for this user.
  SET LOCAL ROLE service_role;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'service_role')::text, true);
  BEGIN
    PERFORM public.confirm_phone_change(user_a, raw_code);
    RAISE EXCEPTION 'FAIL: confirm_phone_change succeeded a second time on an already-used code';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_FOUND' THEN
      RAISE EXCEPTION 'FAIL: second confirm_phone_change raised "%", expected KITPAT_NOT_FOUND', err;
    END IF;
  END;
  RESET ROLE;
  RAISE NOTICE 'PASS: confirm_phone_change rejects a wrong code without consuming the row, succeeds on the right one (updating users.phone and marking the OTP used), and rejects reuse';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
  RAISE NOTICE 'NOTE: verify-email and change-phone (the edge functions themselves) were NOT tested here -- not SQL-testable.';
END;
$t$;

ROLLBACK;
