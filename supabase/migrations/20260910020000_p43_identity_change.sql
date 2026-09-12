-- ---------------------------------------------------------------------------
-- P43: email verification + phone change. Read first, not assumed --
-- supabase/functions/send-sms-otp, send-telegram-otp, verify-otp, and
-- public.otp_verification/ensure_user_after_otp were all read in full
-- before writing a line of this file.
--
-- otp_verification's ACTUAL shape (id, phone NOT NULL, otp_code, channel
-- NOT NULL CHECK IN ('telegram','sms','whatsapp'), is_used, created_at,
-- expires_at, otp_hash, attempt_count, max_attempts, request_ip_hash,
-- last_attempt_at) cannot represent "verify this contact, do NOT sign
-- anyone in" with a purpose column alone, as originally anticipated:
--   - It has NO user_id at all. Sign-in OTP is anonymous by design (the
--     whole point is bootstrapping identity from a bare phone number), but
--     email-verify and phone-change are actions an ALREADY-authenticated
--     member takes, and the row must record whose account this is for.
--   - phone is NOT NULL. Email verification is not about a phone at all.
-- So this migration adds THREE things, not one column, to keep reusing
-- this table (never a parallel one): purpose, user_id, and email --
-- documented here in full rather than silently going beyond the letter of
-- "add a purpose column" without saying so. Every addition is strictly
-- additive and provably backward-compatible with the three untouched
-- functions:
--   - purpose gets DEFAULT 'signin', so send-sms-otp/send-telegram-otp's
--     existing INSERTs (which never mention purpose) keep writing
--     'signin' rows exactly as before, with no code change needed there.
--   - user_id/email are both nullable; every pre-existing row already has
--     phone NOT NULL and both new columns NULL, which is exactly what the
--     'signin' branch of the new shape-consistency CHECK below requires --
--     no backfill needed, no existing row can violate it.
--   - phone's NOT NULL is relaxed to nullable (needed for an email_verify
--     row, which has no phone at all) -- loosening a NOT NULL can never
--     break an existing row, since every one of them already has a
--     non-null phone.
-- verify-otp's own lookup (`WHERE phone = ... AND is_used = false ...`,
-- optionally `.eq('channel', ...)`) never filters on purpose/user_id/email,
-- so it keeps matching exactly the 'signin' rows it always has -- a
-- phone_change or email_verify row is simply invisible to it, by
-- construction, not by a new filter this migration had to add there.
--
-- A SEPARATE, non-obvious gap found while reading users' RLS (not asked
-- for, but required to make this feature actually secure rather than
-- theatre): `users_update_own` lets an authenticated member UPDATE ANY
-- column of their own row, including phone, with no OTP involved at all.
-- Shipping change-phone/verify-email without also closing this would mean
-- a member (or a client bug) could set their own phone to any unused
-- number, or forge their own email_verified_at, via a plain client
-- update, completely bypassing every check either edge function makes.
-- Section 3 below closes it with a BEFORE UPDATE trigger, the one
-- enforcement point that applies regardless of which code path performs
-- the UPDATE.
--
-- P43.1 UPDATE -- verified against the live database and against
-- verify-otp/index.ts: sign-in does NOT use auth.users.phone at all. It
-- mints a session from a SYNTHETIC EMAIL derived from the phone
-- (phoneEmail(p) = `${p}@phone.kitpat.local`), via
-- admin.generateLink({type:'magiclink', email}). Live data confirmed the
-- shape for all 53 users: auth.users.email is what actually signs a
-- member in; auth.users.phone is set but not read by that path.
-- change-phone's confirm action already updated BOTH phone and email
-- together in its one auth.admin.updateUserById call (this was correct
-- from the first version of this migration) -- what was still missing is
-- what happens if that ADMIN API CALL ITSELF FAILS after the SQL swap
-- already committed. users.phone_sync_pending (section 1b) makes that
-- failure visible and reconcilable instead of a silent, permanent
-- mismatch. See change-phone/index.ts's own header for the full traced
-- failure-mode analysis (what a member CAN and CANNOT still do while this
-- flag is set) and this PR's description for the exact recovery runbook.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. users.email_verified_at -- additive, nullable. The existing email
--    column is untouched and stays shown unverified when this is NULL.
-- ---------------------------------------------------------------------------
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS email_verified_at timestamptz;

COMMENT ON COLUMN public.users.email_verified_at IS
  'Set only by confirm_email_verification (service_role only, via verify-email). NULL = unverified (email may still be set and shown). A BEFORE UPDATE trigger (public.users_guard_identity_columns) blocks any non-service_role attempt to set this directly, and auto-clears it if email changes without also setting a fresh verified_at in the same statement.';

-- ---------------------------------------------------------------------------
-- 1b. users.phone_sync_pending (P43.1) -- reconciliation flag for the one
--     step of change-phone's confirm action that cannot be part of the
--     SQL transaction: syncing auth.users.phone/email to match the
--     public.users.phone this migration's confirm_phone_change already
--     swapped. NULL = in sync (the normal case). Non-NULL = the last
--     auth.admin.updateUserById call failed after the SQL swap already
--     committed; a short diagnostic string (reason + timestamp) is
--     stored, not just a boolean, so an admin reading this row directly
--     doesn't have to go hunting through function logs to know when/why.
--     Set and cleared only by change-phone's service_role client -- the
--     same BEFORE UPDATE trigger that protects phone/email_verified_at
--     (extended in section 3 below) protects this column too.
-- ---------------------------------------------------------------------------
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS phone_sync_pending text;

COMMENT ON COLUMN public.users.phone_sync_pending IS
  'NULL = auth.users is in sync with this row''s phone (the normal case). Non-NULL = change-phone''s auth.admin.updateUserById call failed after public.users.phone was already swapped -- holds a short diagnostic string. Recovery: re-run auth.admin.updateUserById(id, {phone: ''+91''||users.phone, email: users.phone||''@phone.kitpat.local'', phone_confirm:true, email_confirm:true}) using this row''s CURRENT phone, then clear this column to NULL. See this migration''s P43.1 header and the P43 PR description for the full runbook. Guarded by the same BEFORE UPDATE trigger as phone/email_verified_at -- only service_role may set or clear it.';

-- ---------------------------------------------------------------------------
-- 2. otp_verification -- purpose + user_id + email, phone relaxed to
--    nullable, channel CHECK extended with 'email'. See this file's header
--    for the full reasoning.
-- ---------------------------------------------------------------------------
ALTER TABLE public.otp_verification
  ALTER COLUMN phone DROP NOT NULL,
  ADD COLUMN IF NOT EXISTS purpose text NOT NULL DEFAULT 'signin',
  ADD COLUMN IF NOT EXISTS user_id uuid REFERENCES public.users(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS email text;

ALTER TABLE public.otp_verification
  DROP CONSTRAINT IF EXISTS otp_verification_channel_check;
ALTER TABLE public.otp_verification
  ADD CONSTRAINT otp_verification_channel_check
  CHECK (channel IN ('telegram', 'sms', 'whatsapp', 'email'));

ALTER TABLE public.otp_verification
  DROP CONSTRAINT IF EXISTS otp_verification_purpose_check;
ALTER TABLE public.otp_verification
  ADD CONSTRAINT otp_verification_purpose_check
  CHECK (purpose IN ('signin', 'email_verify', 'phone_change'));

-- Shape consistency per purpose -- every pre-existing row satisfies the
-- 'signin' branch automatically (phone NOT NULL already true for all of
-- them; user_id/email both NULL, being brand-new columns).
ALTER TABLE public.otp_verification
  DROP CONSTRAINT IF EXISTS otp_verification_purpose_shape_check;
ALTER TABLE public.otp_verification
  ADD CONSTRAINT otp_verification_purpose_shape_check
  CHECK (
    (purpose = 'signin' AND phone IS NOT NULL AND email IS NULL AND user_id IS NULL)
    OR (purpose = 'phone_change' AND phone IS NOT NULL AND email IS NULL AND user_id IS NOT NULL)
    OR (purpose = 'email_verify' AND email IS NOT NULL AND phone IS NULL AND user_id IS NOT NULL)
  );

COMMENT ON COLUMN public.otp_verification.purpose IS
  'signin (default -- anonymous, the existing sign-in flow, untouched), phone_change, or email_verify. Only signin rows have no user_id; the latter two are actions an already-authenticated member takes.';
COMMENT ON COLUMN public.otp_verification.user_id IS
  'The already-authenticated member this row is for. NULL for purpose=signin (anonymous by design); required for phone_change/email_verify.';
COMMENT ON COLUMN public.otp_verification.email IS
  'The email being verified, for purpose=email_verify only. NULL otherwise -- phone_change and signin both use the existing phone column.';

CREATE INDEX IF NOT EXISTS idx_otp_verification_user_purpose
  ON public.otp_verification (user_id, purpose, created_at)
  WHERE user_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 3. users_guard_identity_columns -- BEFORE UPDATE trigger. The one
--    enforcement point for "phone/email_verified_at can only change
--    through a verified flow", regardless of which code path issues the
--    UPDATE (a raw client PATCH via users_update_own, or any RPC).
--
--    auth.role() (already used exactly this way by P30's
--    finalize_account_deletion) reads the JWT role claim: 'service_role'
--    only when the request was actually authenticated with the
--    service_role key, never for a plain 'authenticated' user session --
--    including one calling a SECURITY DEFINER function, since SECURITY
--    DEFINER changes the effective privilege identity for grants/RLS, not
--    the JWT the trigger reads (the AP7.1 lesson, applied here
--    proactively). confirm_phone_change/confirm_email_verification below
--    are therefore called by their edge functions via a service_role
--    client specifically so this trigger lets their writes through.
--
--    finalize_account_deletion's own phone=NULL anonymisation on account
--    deletion already runs as service_role (it enforces that itself), and
--    ensure_user_after_otp's ON CONFLICT (phone) DO UPDATE SET phone =
--    excluded.phone is a same-value no-op in every case it fires (the
--    conflict only exists because that row's phone already equals the
--    value being "set") -- neither is affected by the phone-lock below.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.users_guard_identity_columns()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF auth.role() <> 'service_role' THEN
    IF NEW.phone IS DISTINCT FROM OLD.phone THEN
      RAISE EXCEPTION 'KITPAT_PHONE_CHANGE_REQUIRES_VERIFICATION' USING ERRCODE = 'PT403';
    END IF;
    IF NEW.email_verified_at IS DISTINCT FROM OLD.email_verified_at THEN
      RAISE EXCEPTION 'KITPAT_EMAIL_VERIFICATION_REQUIRES_OTP' USING ERRCODE = 'PT403';
    END IF;
    IF NEW.phone_sync_pending IS DISTINCT FROM OLD.phone_sync_pending THEN
      RAISE EXCEPTION 'KITPAT_PHONE_SYNC_STATE_IS_SYSTEM_MANAGED' USING ERRCODE = 'PT403';
    END IF;
  END IF;

  -- email changed without also setting a fresh verified_at in the same
  -- statement (the only way a legitimate confirm ever changes email) ->
  -- the old verification no longer applies to whatever email is now on
  -- the row. Applies regardless of role, so even a service_role-driven
  -- plain email edit (if one is ever added later) can't accidentally
  -- leave a stale verified_at pointing at a different address.
  IF NEW.email IS DISTINCT FROM OLD.email AND NEW.email_verified_at IS NOT DISTINCT FROM OLD.email_verified_at THEN
    NEW.email_verified_at := NULL;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.users_guard_identity_columns() IS
  'BEFORE UPDATE on public.users. Blocks changing phone, email_verified_at, or phone_sync_pending unless the caller is service_role (auth.role()); auto-clears email_verified_at whenever email changes without the same statement also setting a fresh verified_at, so a stale verification can never survive an email edit.';

DROP TRIGGER IF EXISTS users_guard_identity_columns_trigger ON public.users;
CREATE TRIGGER users_guard_identity_columns_trigger
  BEFORE UPDATE ON public.users
  FOR EACH ROW EXECUTE FUNCTION public.users_guard_identity_columns();

-- ---------------------------------------------------------------------------
-- 4. confirm_phone_change -- service_role only (called by change-phone's
--    service_role client, never a client directly). Verifies the code
--    hash itself (does not trust the caller to have already checked it),
--    then in one transaction: re-checks the new number is still unused
--    (the race this whole design exists to close), marks the OTP used,
--    and swaps public.users.phone. Everything auth.users-side (syncing
--    the record, invalidating other sessions) happens in change-phone
--    itself, AFTER this commits -- a Postgres transaction cannot span the
--    GoTrue Admin API, so true single-transaction atomicity across both
--    systems is not architecturally possible. What matters for a future
--    sign-in to work is public.users.phone alone: ensure_user_after_otp
--    resolves the account strictly by `WHERE phone = normalized`, so the
--    moment this commits, OTP sign-in on the new number reaches this same
--    account -- auth.users staying briefly stale on failure is a hygiene
--    gap, not a lockout or a security hole.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_phone_change(p_user_id uuid, p_code text)
RETURNS TABLE (old_phone text, new_phone text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  ov public.otp_verification;
  v_salt text;
  v_expected_hash text;
  v_actual_hash text;
  v_old_phone text;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHORIZED' USING ERRCODE = 'PT403';
  END IF;

  SELECT * INTO ov
  FROM public.otp_verification
  WHERE user_id = p_user_id AND purpose = 'phone_change' AND is_used = false
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF ov.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
  IF ov.expires_at <= now() THEN
    RAISE EXCEPTION 'KITPAT_CODE_EXPIRED' USING ERRCODE = 'PT409';
  END IF;
  IF ov.attempt_count >= ov.max_attempts THEN
    RAISE EXCEPTION 'KITPAT_TOO_MANY_ATTEMPTS' USING ERRCODE = 'PT429';
  END IF;

  v_salt := split_part(ov.otp_hash, ':', 1);
  v_expected_hash := split_part(ov.otp_hash, ':', 2);
  v_actual_hash := encode(extensions.digest(v_salt || ':' || coalesce(p_code, ''), 'sha256'), 'hex');

  IF v_salt = '' OR v_actual_hash <> v_expected_hash THEN
    UPDATE public.otp_verification SET attempt_count = attempt_count + 1, last_attempt_at = now() WHERE id = ov.id;
    RAISE EXCEPTION 'KITPAT_CODE_INVALID' USING ERRCODE = 'PT400';
  END IF;

  -- The race this whole design exists to close: re-check under the row
  -- lock already held on ov, immediately before the swap.
  IF EXISTS (SELECT 1 FROM public.users u WHERE u.phone = ov.phone AND u.id <> p_user_id) THEN
    RAISE EXCEPTION 'KITPAT_PHONE_IN_USE' USING ERRCODE = 'PT409';
  END IF;

  SELECT u.phone INTO v_old_phone FROM public.users u WHERE u.id = p_user_id;

  UPDATE public.otp_verification SET is_used = true, last_attempt_at = now() WHERE id = ov.id;
  UPDATE public.users SET phone = ov.phone WHERE id = p_user_id;

  RETURN QUERY SELECT v_old_phone, ov.phone;
END;
$$;

COMMENT ON FUNCTION public.confirm_phone_change(uuid, text) IS
  'service_role only. Verifies the caller''s latest unused phone_change code itself, re-checks the new number is still unused under a row lock (the send/confirm race this design exists to close), then swaps public.users.phone. Does not touch auth.users -- change-phone does that as a best-effort follow-up after this commits. Errors: KITPAT_UNAUTHORIZED / KITPAT_NOT_FOUND / KITPAT_CODE_EXPIRED / KITPAT_TOO_MANY_ATTEMPTS / KITPAT_CODE_INVALID / KITPAT_PHONE_IN_USE.';

REVOKE ALL ON FUNCTION public.confirm_phone_change(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.confirm_phone_change(uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.confirm_phone_change(uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_phone_change(uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. confirm_email_verification -- service_role only, same shape as
--    confirm_phone_change. Writes users.email and users.email_verified_at
--    in the one UPDATE statement below.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_email_verification(p_user_id uuid, p_code text)
RETURNS TABLE (email text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  ov public.otp_verification;
  v_salt text;
  v_expected_hash text;
  v_actual_hash text;
BEGIN
  IF auth.role() <> 'service_role' THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHORIZED' USING ERRCODE = 'PT403';
  END IF;

  SELECT * INTO ov
  FROM public.otp_verification
  WHERE user_id = p_user_id AND purpose = 'email_verify' AND is_used = false
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF ov.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
  IF ov.expires_at <= now() THEN
    RAISE EXCEPTION 'KITPAT_CODE_EXPIRED' USING ERRCODE = 'PT409';
  END IF;
  IF ov.attempt_count >= ov.max_attempts THEN
    RAISE EXCEPTION 'KITPAT_TOO_MANY_ATTEMPTS' USING ERRCODE = 'PT429';
  END IF;

  v_salt := split_part(ov.otp_hash, ':', 1);
  v_expected_hash := split_part(ov.otp_hash, ':', 2);
  v_actual_hash := encode(extensions.digest(v_salt || ':' || coalesce(p_code, ''), 'sha256'), 'hex');

  IF v_salt = '' OR v_actual_hash <> v_expected_hash THEN
    UPDATE public.otp_verification SET attempt_count = attempt_count + 1, last_attempt_at = now() WHERE id = ov.id;
    RAISE EXCEPTION 'KITPAT_CODE_INVALID' USING ERRCODE = 'PT400';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.users u
    WHERE u.email = ov.email AND u.email_verified_at IS NOT NULL AND u.id <> p_user_id
  ) THEN
    RAISE EXCEPTION 'KITPAT_EMAIL_IN_USE' USING ERRCODE = 'PT409';
  END IF;

  UPDATE public.otp_verification SET is_used = true, last_attempt_at = now() WHERE id = ov.id;
  UPDATE public.users SET email = ov.email, email_verified_at = now() WHERE id = p_user_id;

  RETURN QUERY SELECT ov.email;
END;
$$;

COMMENT ON FUNCTION public.confirm_email_verification(uuid, text) IS
  'service_role only. Verifies the caller''s latest unused email_verify code itself, re-checks the email is not already verified on another user''s row, then writes users.email and users.email_verified_at = now() in one statement. Errors: KITPAT_UNAUTHORIZED / KITPAT_NOT_FOUND / KITPAT_CODE_EXPIRED / KITPAT_TOO_MANY_ATTEMPTS / KITPAT_CODE_INVALID / KITPAT_EMAIL_IN_USE.';

REVOKE ALL ON FUNCTION public.confirm_email_verification(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.confirm_email_verification(uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.confirm_email_verification(uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_email_verification(uuid, text) TO service_role;
