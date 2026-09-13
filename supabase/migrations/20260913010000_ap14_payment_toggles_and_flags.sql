-- ---------------------------------------------------------------------------
-- AP14: payment gateway toggles (Razorpay + PayU, both independently
-- switchable, both default OFF) and coverage for 13 already-shipped
-- features that had no flag, all seeded via public.feature_flags -- no new
-- table.
--
-- public.feature_flags was read in full first (appears only in
-- 20260801140136_remote_schema.sql, never altered since): PK on "key",
-- columns (key, label, description, is_enabled, category, updated_at,
-- updated_by), updated_by is a plain FK to public.users(id), no CHECK on
-- category (free to add a new 'payments' value). Grepping every migration
-- for "INSERT INTO.*feature_flags" returns nothing -- the 25 existing rows
-- were seeded outside migration history, so their exact keys/values cannot
-- be enumerated from this repo; the test file proves the seeding mechanism
-- (ON CONFLICT (key) DO NOTHING) rather than asserting specific historical
-- values it has no way to know.
--
-- flags_admin_write (USING admins.user_id) is, like every other policy on
-- that dead column found so far this session (razorpay_events_admin_only,
-- AP6's get_user_plan_limits bypass), non-functional for any real AP0-era
-- admin (admins.user_id is never populated by the email/role system) --
-- this is why admin_set_feature_flag exists below rather than relying on
-- flags_admin_write directly, exactly as admin_can_write (AP1) exists
-- instead of relying on the content tables' own admin policies. Not fixed
-- here (out of scope); flags_public_read is untouched, per the task.
--
-- KNOWN SCHEMA MISMATCH, flagged rather than worked around: feature_flags.
-- updated_by is FK'd to public.users(id), the MEMBER identity space
-- (phone-keyed, no email column at all -- confirmed by reading users' full
-- column list). public.admins is a disjoint, email-keyed office-staff
-- table with no reliable link to a users row (admins.user_id is the same
-- unpopulated legacy column referenced above). There is therefore no
-- honest users.id to put in updated_by when an admin makes this call --
-- admin_set_feature_flag leaves it NULL rather than inventing a mapping.
-- The real, correct attribution record is the admin_audit row this
-- function writes via log_admin_action (actor_admin_id/actor_email,
-- admins-keyed) -- updated_by/updated_at on feature_flags itself is best
-- read as "last touched at, by a human" rather than "by which admin."
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Payment gateway toggles -- category 'payments', both default OFF.
--    Nothing charges anyone until an admin turns one on.
-- ---------------------------------------------------------------------------
INSERT INTO public.feature_flags (key, label, description, is_enabled, category)
VALUES
  ('gateway_razorpay', 'Razorpay payments',
   'Lets members pay for a plan using Razorpay (cards, UPI, netbanking, wallets). Turn this on once Razorpay is ready to accept live payments.',
   false, 'payments'),
  ('gateway_payu', 'PayU payments',
   'Lets members pay for a plan using PayU (cards, UPI, netbanking, wallets). Turn this on once PayU is ready to accept live payments.',
   false, 'payments')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Flag coverage for already-shipped features. All TRUE so nothing
--    changes behaviour on deploy. ON CONFLICT (key) DO NOTHING: safe to
--    re-run, never overwrites an existing flag's state.
-- ---------------------------------------------------------------------------
INSERT INTO public.feature_flags (key, label, description, is_enabled, category)
VALUES
  ('food_tracking', 'Food tracking',
   'Lets members log what they ate, either by typing a description or from a photo.',
   true, 'features'),
  ('food_image_input', 'Food logging from a photo',
   'Lets members snap a photo of their food instead of typing a description; an AI provider identifies the dish.',
   true, 'features'),
  ('memories', 'Memories',
   'Lets members save and share photos/moments tied to a group, so a party''s highlights stay in one place.',
   true, 'features'),
  ('kitty_ledger', 'Kitty ledger',
   'The shared money pool for a group: contributions in, expenses out, with a running balance everyone can see.',
   true, 'features'),
  ('group_invites', 'Group invites',
   'Lets a host invite new people into a group via a shareable link or code.',
   true, 'features'),
  ('party_recap', 'Party recap',
   'Shows a summary of a group''s event afterwards -- who came, what was spent, highlights from the ledger and memories.',
   true, 'features'),
  ('emoji_guess', 'Emoji Guess game',
   'A party game where players guess a word or phrase from a string of emoji.',
   true, 'games'),
  ('rapid_fire', 'Rapid Fire game',
   'A fast-paced quiz-style party game with quick-answer rounds.',
   true, 'games'),
  ('who_knows_who', 'Who Knows Who game',
   'A party game that tests how well the group knows each other.',
   true, 'games'),
  ('spin_dare', 'Spin & Dare game',
   'A spin-the-wheel style dare game for the group to play together.',
   true, 'games'),
  ('pass_the_parcel', 'Pass the Parcel game',
   'A digital take on the classic pass-the-parcel party game.',
   true, 'games'),
  ('email_verification', 'Email verification',
   'Lets a member add and verify an email address on their account.',
   true, 'auth'),
  ('phone_change', 'Phone number change',
   'Lets a member change the phone number linked to their account, with OTP verification.',
   true, 'auth')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3. active_payment_gateways() -- the single source of truth for "which
--    gateways can the member app offer right now." Returns the
--    provider-vocabulary keys ('razorpay' / 'payu' -- the exact values
--    payment_events.provider's CHECK already uses, per AP13), not the raw
--    gateway_* flag keys: this is the vocabulary the frontend needs next,
--    to look up that plan's razorpay_plan_id_*/payu_plan_id_* columns.
--    Interpretation call, flagged per this session's convention: the task
--    gives no parameter to accept a specific plan id, so "with the plan
--    ids present for the plan being purchased" is read as describing what
--    the frontend does with this function's result (look up the chosen
--    plan's own id columns for whichever provider key(s) come back), not a
--    computation this RPC performs itself.
--
--    Both on -> both keys, member chooses. One on -> that one key only, no
--    choice shown. Neither on -> empty set, a valid state (checkout
--    unavailable), not an error.
--
--    authenticated + service_role only; anon explicitly revoked (AP8: the
--    ALTER DEFAULT PRIVILEGES grant to anon is baked in at CREATE time
--    regardless of what this migration writes -- REVOKE ALL FROM PUBLIC
--    does not remove it, an explicit REVOKE EXECUTE FROM anon does).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.active_payment_gateways()
RETURNS SETOF text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE f.key
           WHEN 'gateway_razorpay' THEN 'razorpay'
           WHEN 'gateway_payu' THEN 'payu'
         END
  FROM public.feature_flags f
  WHERE f.key IN ('gateway_razorpay', 'gateway_payu')
    AND f.is_enabled = true;
$$;

COMMENT ON FUNCTION public.active_payment_gateways() IS
  'Returns the provider keys (''razorpay''/''payu'', matching payment_events.provider) of whichever payment gateways are currently enabled in feature_flags. Empty result is a valid state (no gateway on -- checkout unavailable), not an error. The frontend must never hardcode a provider; this is the single source of truth. authenticated + service_role only.';

REVOKE ALL ON FUNCTION public.active_payment_gateways() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.active_payment_gateways() FROM anon;
GRANT EXECUTE ON FUNCTION public.active_payment_gateways() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. admin_set_feature_flag -- owner/org_admin only, audited. Writing
--    through flags_admin_write directly would leave no audit trail, and
--    switching a feature off for every user is exactly the kind of action
--    that must be attributable.
--
--    Two separate checks, two separate codes (this IS an admin-domain RPC,
--    unlike P44's member-facing record_contribution/record_expense):
--    KITPAT_ADMIN_ONLY for a caller who is not an active admin at all,
--    KITPAT_INSUFFICIENT_ROLE for an active admin whose role is 'member'
--    (mirrors AP6's admin_update_plan_limits / AP12's
--    admin_delete_food_cache_entry, both owner/org_admin-only).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_feature_flag(p_key text, p_enabled boolean)
RETURNS public.feature_flags
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_admin_id uuid;
  caller_email text;
  before_row jsonb;
  row_out public.feature_flags;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;
  IF public.admin_role() NOT IN ('owner', 'org_admin') THEN
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
  END IF;

  SELECT to_jsonb(f) INTO before_row FROM public.feature_flags f WHERE f.key = p_key;
  IF before_row IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  caller_email := auth.jwt() ->> 'email';
  SELECT id INTO caller_admin_id FROM public.admins WHERE email = caller_email AND is_active = true;

  -- updated_by is left NULL: FK'd to public.users(id), the member identity
  -- space, which has no honest row for an admin caller here -- see the
  -- KNOWN SCHEMA MISMATCH note above. The real attribution is the
  -- admin_audit row below.
  UPDATE public.feature_flags
  SET is_enabled = p_enabled, updated_at = now()
  WHERE key = p_key
  RETURNING * INTO row_out;

  -- Called directly with the admin's own JWT (role=authenticated, not
  -- service_role) -- the AP7.2 guard on log_admin_action accepts this via
  -- is_admin() (already checked above) and, since this is not a
  -- service_role caller, ignores the actor override below and
  -- self-derives the same caller_email/caller_admin_id anyway.
  PERFORM public.log_admin_action(
    'set:feature_flag', 'feature_flags', p_key,
    before_row, to_jsonb(row_out), false, NULL, NULL, caller_admin_id, caller_email
  );

  RETURN row_out;
END;
$$;

COMMENT ON FUNCTION public.admin_set_feature_flag(text, boolean) IS
  'Owner/org_admin only (member admins rejected). Sets is_enabled + updated_at on one feature_flags row and audits the change via log_admin_action. updated_by is left NULL -- it is FK''d to public.users(id), a member identity space admins have no honest row in; the admin_audit row (actor_admin_id/actor_email) is the real attribution record. Errors: KITPAT_ADMIN_ONLY / KITPAT_INSUFFICIENT_ROLE / KITPAT_NOT_FOUND.';

REVOKE ALL ON FUNCTION public.admin_set_feature_flag(text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_feature_flag(text, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_set_feature_flag(text, boolean) TO authenticated, service_role;

-- flags_public_read is untouched, per the task -- the member app must be
-- able to read flags (including the two new gateway_* rows) without an
-- admin session.
