-- Add onboarding profile columns + SECURITY DEFINER user upsert after OTP verify.
-- Anon/authenticated still cannot insert arbitrary users; only service_role may
-- call ensure_user_after_otp, and only with a just-consumed otp_verification row.

-- ---------------------------------------------------------------------------
-- 1. users columns (additive)
-- ---------------------------------------------------------------------------
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS group_interest text,
  ADD COLUMN IF NOT EXISTS onboarding_completed boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.users.city IS 'Optional city collected during onboarding.';
COMMENT ON COLUMN public.users.group_interest IS 'Optional group interest collected during onboarding.';
COMMENT ON COLUMN public.users.onboarding_completed IS 'True once first-run onboarding has been finished.';

-- ---------------------------------------------------------------------------
-- 2. ensure_user_after_otp — SECURITY DEFINER insert/upsert by verified phone
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_user_after_otp(
  p_otp_id uuid,
  p_phone text
) RETURNS public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  ov public.otp_verification;
  normalized text;
  u public.users;
begin
  normalized := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if normalized ~ '^91\d{10}$' then
    normalized := substring(normalized from 3);
  end if;
  if normalized !~ '^\d{10}$' then
    raise exception 'Invalid phone';
  end if;

  select * into ov
  from public.otp_verification
  where id = p_otp_id;

  if ov.id is null then
    raise exception 'OTP record not found';
  end if;
  if ov.phone is distinct from normalized then
    raise exception 'OTP phone mismatch';
  end if;
  if coalesce(ov.is_used, false) is not true then
    raise exception 'OTP not verified';
  end if;
  -- Freshness: must have been consumed in this login window
  if coalesce(ov.last_attempt_at, ov.created_at) < now() - interval '10 minutes' then
    raise exception 'OTP verification expired';
  end if;

  select * into u from public.users where phone = normalized;
  if u.id is not null then
    return u;
  end if;

  insert into public.users as nu (phone, onboarding_completed)
  values (normalized, false)
  on conflict (phone) do update
    set phone = excluded.phone
  returning * into u;

  return u;
end;
$$;

REVOKE ALL ON FUNCTION public.ensure_user_after_otp(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ensure_user_after_otp(uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.ensure_user_after_otp(uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_user_after_otp(uuid, text) TO service_role;
