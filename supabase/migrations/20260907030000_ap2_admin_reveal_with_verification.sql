-- ---------------------------------------------------------------------------
-- AP2: owner-only, double-verified reveal of a user's real phone/email.
--
-- Masking is the default everywhere. Only admin_confirm_reveal, after a
-- correct one-time code AND (at the edge-function layer) a re-entered
-- password, ever returns a raw value -- and every successful reveal is
-- logged as a sensitive admin_audit row (owner-only to read, per AP0).
--
-- users.email: confirmed (not re-derived here) that public.users has never
-- had an email column, and that auth.users.email is a synthetic
-- "<phone>@phone.kitpat.local" placeholder minted by phone-OTP signup
-- (verify-otp/index.ts, ensureAuthUser) -- not real PII for any current
-- user. Per explicit direction: add public.users.email as a new, nullable
-- column, leave it NULL for all existing users (no backfill from
-- auth.users -- that would fabricate a "reveal" of a fake address), and
-- source the 'email' reveal target from public.users.email ONLY, never
-- auth.users. When it is null for a given user, nothing is revealed and
-- no sensitive-reveal audit row is written -- KITPAT_NO_EMAIL_ON_FILE
-- instead, so the audit log never claims a PII reveal that didn't happen.
-- ---------------------------------------------------------------------------

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS email text;

COMMENT ON COLUMN public.users.email IS
  'Real user-supplied email, distinct from auth.users.email (a synthetic <phone>@phone.kitpat.local placeholder minted at phone-OTP signup). NULL until a real email is collected somewhere; never backfilled from auth.users. This is the only source admin_list_users/admin_confirm_reveal read for an ''email'' reveal.';

-- ---------------------------------------------------------------------------
-- 1. admin_list_users -- masked by default, for every admin role.
--    Phone: '+91' + X for every digit but the last 2, e.g. '+91XXXXXXXX10'.
--    Email: local part fully masked, domain shown as-is, e.g.
--    'xxxxxxx@domain.com'. NULL stays NULL (nothing to mask).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_users(
  p_search text DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
) RETURNS TABLE (
  id uuid,
  name text,
  masked_phone text,
  masked_email text,
  city text,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  RETURN QUERY
  SELECT
    u.id,
    u.name,
    CASE WHEN u.phone IS NULL THEN NULL
      ELSE '+91' || repeat('X', greatest(length(u.phone) - 2, 0)) || right(u.phone, 2)
    END,
    CASE WHEN u.email IS NULL THEN NULL
      ELSE repeat('x', greatest(length(split_part(u.email, '@', 1)), 1)) || '@' || split_part(u.email, '@', 2)
    END,
    u.city,
    u.created_at
  FROM public.users u
  WHERE p_search IS NULL OR u.name ILIKE '%' || p_search || '%' OR u.phone ILIKE '%' || p_search || '%'
  ORDER BY u.created_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.admin_list_users(text, int, int) IS
  'Any active admin. Always returns masked_phone/masked_email (never raw phone/email, including to owners) -- p_search matches name or raw phone server-side without ever displaying it unmasked. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_users(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_users(text, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. admin_reveal_requests -- service_role only, no client policy at all.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admin_reveal_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id uuid NOT NULL,
  target_user_id uuid NOT NULL REFERENCES public.users(id),
  field text NOT NULL CHECK (field IN ('phone', 'email')),
  code_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  attempt_count int NOT NULL DEFAULT 0,
  max_attempts int NOT NULL DEFAULT 3,
  consumed_at timestamptz,
  created_at timestamptz DEFAULT now()
);

COMMENT ON TABLE public.admin_reveal_requests IS
  'One-time codes for the owner-only PII reveal flow (salted SHA-256 hash, mirroring otp_verification -- never a plaintext code at rest). No client policy of any kind; only service_role and the SECURITY DEFINER admin_request_reveal/admin_confirm_reveal RPCs (owned by the table owner, which bypasses RLS) ever touch this table.';

ALTER TABLE public.admin_reveal_requests ENABLE ROW LEVEL SECURITY;
-- Deliberately zero policies: RLS default-denies every command for every
-- role that isn't exempt. service_role is exempt (its own role attribute)
-- and holds explicit grants below; anon/authenticated get nothing at all.

REVOKE ALL ON public.admin_reveal_requests FROM anon;
REVOKE ALL ON public.admin_reveal_requests FROM authenticated;
GRANT ALL ON public.admin_reveal_requests TO service_role;

-- ---------------------------------------------------------------------------
-- 3. admin_request_reveal -- owner-only. Generates + salted-hashes a
--    6-digit code (pgcrypto digest(), same salt:hex(sha256) shape as
--    otp_verification.otp_hash), 5-minute expiry.
--
--    The plaintext code IS included in this function's return value --
--    necessary, since something has to know it in order to email it. It is
--    never persisted anywhere in plaintext (only code_hash is stored), and
--    the admin-reveal edge function -- the only intended caller -- must
--    drop it from its own HTTP response back to the browser, returning
--    only { request_id, expires_in } to the client. "NEVER the code
--    itself" describes what reaches the browser, not this RPC's direct
--    (trusted, server-side) caller.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_request_reveal(p_user_id uuid, p_field text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_admin_id uuid;
  target public.users;
  v_code text;
  v_salt text;
  v_code_hash text;
  v_expires timestamptz;
  req_id uuid;
BEGIN
  IF NOT public.is_admin_owner() THEN
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
  END IF;

  IF p_field NOT IN ('phone', 'email') THEN
    RAISE EXCEPTION 'KITPAT_INVALID_FIELD';
  END IF;

  SELECT id INTO caller_admin_id FROM public.admins WHERE email = (auth.jwt() ->> 'email') AND is_active = true;
  IF caller_admin_id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  SELECT * INTO target FROM public.users WHERE id = p_user_id;
  IF target.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  IF p_field = 'email' AND target.email IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NO_EMAIL_ON_FILE' USING ERRCODE = 'PT404';
  END IF;

  v_code := lpad(floor(random() * 1000000)::text, 6, '0');
  v_salt := gen_random_uuid()::text;
  v_code_hash := v_salt || ':' || encode(extensions.digest(v_salt || ':' || v_code, 'sha256'), 'hex');
  v_expires := now() + interval '5 minutes';

  INSERT INTO public.admin_reveal_requests (admin_id, target_user_id, field, code_hash, expires_at)
  VALUES (caller_admin_id, p_user_id, p_field, v_code_hash, v_expires)
  RETURNING id INTO req_id;

  RETURN jsonb_build_object(
    'request_id', req_id,
    'expires_in', extract(epoch FROM (v_expires - now()))::integer,
    'code', v_code
  );
END;
$$;

COMMENT ON FUNCTION public.admin_request_reveal(uuid, text) IS
  'Owner-only. Creates a 5-minute one-time reveal request for p_user_id''s phone or email, storing only a salted SHA-256 hash of the 6-digit code (mirroring otp_verification). Returns the plaintext code to its caller (the admin-reveal edge function, which emails it and must not forward it to the browser) alongside request_id/expires_in. Errors: KITPAT_INSUFFICIENT_ROLE / KITPAT_INVALID_FIELD / KITPAT_ADMIN_ONLY / KITPAT_NOT_FOUND / KITPAT_NO_EMAIL_ON_FILE.';

REVOKE ALL ON FUNCTION public.admin_request_reveal(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_request_reveal(uuid, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. admin_confirm_reveal -- owner-only. Validates ownership, not
--    consumed, not expired, attempt budget, then the code hash. On a
--    correct code, consumes the request immediately (even if the target's
--    email later turns out to be missing -- see below), then logs a
--    sensitive-reveal audit row and returns the one real value.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_confirm_reveal(p_request_id uuid, p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_admin_id uuid;
  caller_email text;
  req public.admin_reveal_requests;
  target public.users;
  v_salt text;
  v_expected_hash text;
  v_actual_hash text;
  v_value text;
BEGIN
  IF NOT public.is_admin_owner() THEN
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
  END IF;

  caller_email := auth.jwt() ->> 'email';
  SELECT id INTO caller_admin_id FROM public.admins WHERE email = caller_email AND is_active = true;
  IF caller_admin_id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  SELECT * INTO req FROM public.admin_reveal_requests WHERE id = p_request_id FOR UPDATE;
  IF req.id IS NULL OR req.admin_id <> caller_admin_id THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  IF req.consumed_at IS NOT NULL OR req.expires_at <= now() THEN
    RAISE EXCEPTION 'KITPAT_REVEAL_CODE_EXPIRED';
  END IF;

  IF req.attempt_count >= req.max_attempts THEN
    RAISE EXCEPTION 'KITPAT_REVEAL_LOCKED';
  END IF;

  v_salt := split_part(req.code_hash, ':', 1);
  v_expected_hash := split_part(req.code_hash, ':', 2);
  v_actual_hash := encode(extensions.digest(v_salt || ':' || coalesce(p_code, ''), 'sha256'), 'hex');

  IF v_actual_hash <> v_expected_hash THEN
    UPDATE public.admin_reveal_requests SET attempt_count = attempt_count + 1 WHERE id = p_request_id;
    RAISE EXCEPTION 'KITPAT_REVEAL_CODE_INVALID';
  END IF;

  -- The code is correct: consume the request now, before the
  -- data-availability check below, so a stale/cleared target field can't
  -- leave a valid, unconsumed code sitting around for a retry.
  UPDATE public.admin_reveal_requests SET consumed_at = now() WHERE id = p_request_id;

  SELECT * INTO target FROM public.users WHERE id = req.target_user_id;
  IF target.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  IF req.field = 'email' AND target.email IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NO_EMAIL_ON_FILE' USING ERRCODE = 'PT404';
  END IF;

  v_value := CASE req.field WHEN 'phone' THEN target.phone WHEN 'email' THEN target.email END;

  PERFORM public.log_admin_action(
    'reveal:' || req.field,
    'users',
    req.target_user_id::text,
    NULL,
    NULL,
    true,
    req.field,
    req.target_user_id::text,
    caller_admin_id,
    caller_email
  );

  RETURN jsonb_build_object('field', req.field, 'value', v_value);
END;
$$;

COMMENT ON FUNCTION public.admin_confirm_reveal(uuid, text) IS
  'Owner-only. Validates the request belongs to the caller, is unconsumed and unexpired (else KITPAT_REVEAL_CODE_EXPIRED), has attempts remaining (else KITPAT_REVEAL_LOCKED), and the code hash matches (else increments attempt_count and raises KITPAT_REVEAL_CODE_INVALID). On success: consumes the request, logs a sensitive admin_audit row, and returns {field, value} -- the one real value, nothing else. Errors: KITPAT_INSUFFICIENT_ROLE / KITPAT_ADMIN_ONLY / KITPAT_NOT_FOUND / KITPAT_REVEAL_CODE_EXPIRED / KITPAT_REVEAL_LOCKED / KITPAT_REVEAL_CODE_INVALID / KITPAT_NO_EMAIL_ON_FILE.';

REVOKE ALL ON FUNCTION public.admin_confirm_reveal(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_confirm_reveal(uuid, text) TO authenticated, service_role;
