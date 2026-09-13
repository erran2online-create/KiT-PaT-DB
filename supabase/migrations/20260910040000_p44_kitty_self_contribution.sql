-- ---------------------------------------------------------------------------
-- P44: a member may record her OWN kitty contribution; record_contribution
-- and record_expense raise stable KITPAT_* codes instead of plain English.
--
-- record_contribution/record_expense's current bodies were read in full
-- from 20260824030000_p33_1_kitty_ledger_decimals.sql (the latest CREATE OR
-- REPLACE of each -- confirmed by grepping every migration that mentions
-- either name) before writing this. Both are CREATE OR REPLACE'd here with
-- their EXACT existing signatures -- no parameter renamed, reordered,
-- retyped, or dropped.
--
-- set_pool_expected/void_contribution/void_kitty_expense/get_kitty_balance
-- were also read in full first, to reuse this domain's existing KITPAT_*
-- vocabulary rather than inventing a parallel one:
--   KITPAT_UNAUTHENTICATED (PT401), KITPAT_INVALID_AMOUNT (PT400),
--   KITPAT_NOT_FOUND (PT404), KITPAT_NOT_HOST (PT403, host-only actions),
--   KITPAT_NOT_MEMBER (PT403, caller/target recognized as neither member
--   nor host).
--
-- P44.1 CORRECTION: the first version of this migration used
-- KITPAT_INSUFFICIENT_ROLE for both functions' role rejection, per an
-- earlier instruction. That instruction was wrong and has been corrected,
-- verified live: KITPAT_INSUFFICIENT_ROLE is an admin-domain code (5 uses,
-- all in AP-series admin RPCs) with ZERO handling anywhere in the member
-- frontend -- a member hitting it would get a generic, untranslated error.
-- KITPAT_INSUFFICIENT_ROLE is REMOVED from both functions entirely.
-- Corrected to this domain's own, already-frontend-handled codes:
--   KITPAT_NOT_HOST   -- src/parties/api.ts:445 (7 live uses: set_pool_
--                        expected, void_contribution, void_kitty_expense)
--   KITPAT_NOT_MEMBER -- src/kitty/api.ts:34, "kitty.error.notmember"
--                        (2 live uses, including get_kitty_balance)
--
-- record_contribution's three-way permission split:
--   - caller is not a member of pool.group_id at all -> KITPAT_NOT_MEMBER
--   - caller IS a member but p_user_id is someone else, and caller is not
--     the host -> KITPAT_NOT_HOST
--   - p_user_id = auth.uid() and caller is a member -> ALLOW
-- A host is checked FIRST and always allowed regardless of target (self or
-- any other member), exactly as before this feature existed -- none of the
-- three bullets above ever apply to a host, since is_group_host is
-- unconditional and short-circuits ahead of them.
--
-- record_expense: unchanged host-only permission, now raising KITPAT_NOT_HOST
-- (reverted from the incorrect KITPAT_INSUFFICIENT_ROLE) rather than a
-- brand new code -- the exact code set_pool_expected/void_* already use for
-- the identical "caller is not the host" condition.
--
-- The "target user is not a member or host of this group" check inside
-- record_contribution (unchanged logic, only its message converted) reuses
-- KITPAT_NOT_MEMBER: the meaning ("this uuid isn't recognized as part of
-- this group") is identical to get_kitty_balance's use of it for the
-- caller's own membership, just applied here to a named target instead.
--
-- Grants, RLS, and the contributions/kitty_expenses tables are untouched.
-- record_expense, set_pool_expected, create_kitty_pool, void_contribution
-- and void_kitty_expense keep their exact existing permission logic --
-- only record_contribution's permission check changes.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. record_contribution -- split permission: a member may record her own
--    contribution; recording against anyone else stays host-only. Every
--    other check (amount positive, pool exists/locked, target is a member
--    or host, pool total re-settles in the same transaction) is unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_contribution(
  p_pool_id uuid,
  p_user_id uuid,
  p_amount numeric,
  p_method text DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_receipt_media_id uuid DEFAULT NULL
) RETURNS public.contributions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  pool public.kitty_pools;
  contrib public.contributions;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'KITPAT_INVALID_AMOUNT' USING ERRCODE = 'PT400';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = p_pool_id FOR UPDATE;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  -- Host: allowed regardless of target (self or any other member), exactly
  -- as before this feature existed. Checked first so none of the three
  -- cases below ever apply to a host.
  IF NOT public.is_group_host(pool.group_id, uid) THEN
    IF p_user_id = uid AND public.is_group_member(pool.group_id, uid) THEN
      -- A member recording her own contribution -- allowed.
      NULL;
    ELSIF NOT public.is_group_member(pool.group_id, uid) THEN
      RAISE EXCEPTION 'KITPAT_NOT_MEMBER' USING ERRCODE = 'PT403';
    ELSE
      -- Caller is a member, but is trying to record against someone else
      -- without being the host.
      RAISE EXCEPTION 'KITPAT_NOT_HOST' USING ERRCODE = 'PT403';
    END IF;
  END IF;

  IF NOT public.is_group_member(pool.group_id, p_user_id)
     AND NOT public.is_group_host(pool.group_id, p_user_id) THEN
    RAISE EXCEPTION 'KITPAT_NOT_MEMBER' USING ERRCODE = 'PT403';
  END IF;

  INSERT INTO public.contributions (
    pool_id, user_id, amount, method, paid_at, receipt_media_id, note
  ) VALUES (
    p_pool_id, p_user_id, p_amount, p_method, now(), p_receipt_media_id, p_note
  )
  RETURNING * INTO contrib;

  UPDATE public.kitty_pools
  SET total_collected = total_collected + p_amount
  WHERE id = p_pool_id;

  PERFORM public.tag_media_as_receipt(p_receipt_media_id);

  RETURN contrib;
END;
$$;

COMMENT ON FUNCTION public.record_contribution(uuid, uuid, numeric, text, text, uuid) IS
  'A member may record her own contribution (p_user_id = auth.uid() and a group member); recording against any other user stays host-only. Amount is numeric(12,2) end to end: no rounding to whole rupees. Errors: KITPAT_UNAUTHENTICATED / KITPAT_INVALID_AMOUNT / KITPAT_NOT_FOUND / KITPAT_NOT_MEMBER (caller, or the target, is not recognized as part of the group) / KITPAT_NOT_HOST (a non-host caller tried to record against someone else).';

-- ---------------------------------------------------------------------------
-- 2. record_expense -- host-only, unchanged permission logic. Only its
--    English exception strings are converted to KITPAT_* codes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_expense(
  p_pool_id uuid,
  p_amount numeric,
  p_vendor text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_receipt_media_id uuid DEFAULT NULL,
  p_note text DEFAULT NULL
) RETURNS public.kitty_expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  pool public.kitty_pools;
  exp public.kitty_expenses;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'KITPAT_INVALID_AMOUNT' USING ERRCODE = 'PT400';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = p_pool_id FOR UPDATE;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
  IF NOT public.is_group_host(pool.group_id, uid) THEN
    RAISE EXCEPTION 'KITPAT_NOT_HOST' USING ERRCODE = 'PT403';
  END IF;

  INSERT INTO public.kitty_expenses (
    pool_id, added_by, amount, vendor, category, receipt_media_id, note
  ) VALUES (
    p_pool_id, uid, p_amount, p_vendor, p_category, p_receipt_media_id, p_note
  ) RETURNING * INTO exp;

  UPDATE public.kitty_pools
  SET total_spent = total_spent + p_amount
  WHERE id = p_pool_id;

  PERFORM public.tag_media_as_receipt(p_receipt_media_id);

  RETURN exp;
END;
$$;

COMMENT ON FUNCTION public.record_expense(uuid, numeric, text, text, uuid, text) IS
  'Host-only, unchanged from before this migration -- only its exception messages are now stable codes. Amount is numeric(12,2) end to end: no rounding to whole rupees. Errors: KITPAT_UNAUTHENTICATED / KITPAT_INVALID_AMOUNT / KITPAT_NOT_FOUND / KITPAT_NOT_HOST.';

-- No GRANT/REVOKE statements here, deliberately: "do not change grants".
-- CREATE OR REPLACE FUNCTION with an identical signature does not alter a
-- function's existing ACL in Postgres, so both functions keep exactly the
-- grants they already had (record_expense's own from its last CREATE OR
-- REPLACE in 20260824030000_p33_1_kitty_ledger_decimals.sql; record_
-- contribution's from whichever earlier migration last matched this exact
-- signature) without this migration needing to touch them at all.
