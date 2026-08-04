-- P7.1: otp_code is unused (otp_hash is the source of truth). Send functions
-- inserted otp_code: null, which silently failed NOT NULL and returned success
-- after Telegram/SMS already delivered the code — verify then saw no row → "expired".

ALTER TABLE public.otp_verification
  ALTER COLUMN otp_code DROP NOT NULL;

COMMENT ON COLUMN public.otp_verification.otp_code IS
  'Deprecated plaintext; nullable. Verification uses otp_hash only.';
