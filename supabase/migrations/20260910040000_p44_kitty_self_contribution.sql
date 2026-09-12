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
-- ONE deliberate departure from that reuse, flagged rather than silently
-- done: the task's own explicit instruction (both its "at minimum" list
-- and its test assertions) names KITPAT_INSUFFICIENT_ROLE for
-- record_contribution/record_expense's host-only rejection, not this
-- domain's existing KITPAT_NOT_HOST (used by set_pool_expected and
-- void_contribution/void_kitty_expense for the identical "caller is not
-- the host" condition). KITPAT_INSUFFICIENT_ROLE is not a new invention --
-- it already exists in this codebase's vocabulary (the admin-surface RPCs,
-- e.g. admin_can_write, admin_void_ledger_entry) -- but it is a different
-- name than this specific function family has used for the same concept
-- until now. Followed the task's explicit instruction over the general
-- "match this domain's own names" principle, since it names the exact
-- code twice, explicitly. Worth a second look if KITPAT_NOT_HOST was
-- actually intended for consistency with set_pool_expected/void_*.
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

  -- A member may always record her own contribution. Recording against
  -- anyone else stays host-only -- is_group_host is still checked
  -- unconditionally here, so a host recording for themselves or for
  -- another member both continue to work exactly as before.
  IF NOT (
    (p_user_id = uid AND public.is_group_member(pool.group_id, uid))
    OR public.is_group_host(pool.group_id, uid)
  ) THEN
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
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
  'A member may record her own contribution (p_user_id = auth.uid() and a group member); recording against any other user stays host-only. Amount is numeric(12,2) end to end: no rounding to whole rupees. Errors: KITPAT_UNAUTHENTICATED / KITPAT_INVALID_AMOUNT / KITPAT_NOT_FOUND / KITPAT_INSUFFICIENT_ROLE / KITPAT_NOT_MEMBER.';

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
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
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
  'Host-only, unchanged from before this migration -- only its exception messages are now stable codes. Amount is numeric(12,2) end to end: no rounding to whole rupees. Errors: KITPAT_UNAUTHENTICATED / KITPAT_INVALID_AMOUNT / KITPAT_NOT_FOUND / KITPAT_INSUFFICIENT_ROLE.';

-- No GRANT/REVOKE statements here, deliberately: "do not change grants".
-- CREATE OR REPLACE FUNCTION with an identical signature does not alter a
-- function's existing ACL in Postgres, so both functions keep exactly the
-- grants they already had (record_expense's own from its last CREATE OR
-- REPLACE in 20260824030000_p33_1_kitty_ledger_decimals.sql; record_
-- contribution's from whichever earlier migration last matched this exact
-- signature) without this migration needing to touch them at all.
