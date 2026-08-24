-- P33.1: kitty ledger money columns integer -> numeric(12,2). No more paise loss.
--
-- Live state confirmed before writing this (not re-queried; no DB access):
-- contributions.amount, kitty_expenses.amount, expenses.amount and
-- events.contribution_amount are ALL integer today. record_contribution,
-- record_expense, confirm_ocr_expense, void_contribution, void_kitty_expense
-- and get_kitty_balance all exist.
--
-- CRITICAL per the task: get_kitty_balance, void_contribution and
-- void_kitty_expense were rewritten by P26 (20260822130000) and P27
-- (20260823120000). Both were re-read in full from the repo (not from memory)
-- immediately before writing this file. Their voided-row exclusion
-- (voided_at IS NULL filters), the P27 frozen output contract (ok,
-- expected_per_member, members[] with name/amount_paid/amount_pending/status,
-- plus the P26 diagnostic totals_consistent/voided_contributions/
-- voided_expenses keys), and every stable KITPAT_* code are preserved
-- unchanged below. The only thing that changes is the money type: a field
-- that was a JSON integer (e.g. collected: 500) is now a JSON number that
-- can carry cents (e.g. collected: 1250.50) — same field, same meaning, same
-- shape, per the task's explicit instruction to change ONLY the money type.
--
-- Scope note: the task named four columns (contributions.amount,
-- kitty_expenses.amount, expenses.amount, events.contribution_amount).
-- Reading record_contribution/record_expense/get_kitty_balance showed that
-- kitty_pools.total_collected and kitty_pools.total_spent are the running
-- accumulators those four columns are written into and read back from —
-- left as integer, `total_collected + p_amount` with a numeric p_amount
-- would implicitly round back down to an integer on write, and
-- get_kitty_balance's 'collected'/'spent'/'balance' keys read pool.total_*
-- directly rather than re-summing the ledger. Leaving them integer would
-- make the task's own test case (1250.50 must read back exactly in
-- get_kitty_balance) fail outright. So kitty_pools.total_collected and
-- total_spent are ALSO converted here, as a direct, unavoidable consequence
-- of converting the four named columns, not as separate scope. Reported
-- explicitly rather than done silently, per this repo's rule to flag any
-- such gap instead of assuming past it. kitty_pools.expected_per_member is
-- deliberately left as integer: it is not written by record_contribution/
-- record_expense and nothing truncates through it, so there is no
-- correctness reason to touch it, and the task did not ask for it.
--
-- Also required as a direct consequence: n8n_events_due_in_24h() declares
-- `contribution_amount integer` in its RETURNS TABLE — that must match
-- events.contribution_amount's new type exactly or the function breaks the
-- next time it runs. Updated below; its logic is otherwise untouched.
--
-- Of the six named functions, void_contribution and void_kitty_expense
-- (P26) needed NO code change at all: neither has any numeric->integer cast
-- in its body (their re-settle UPDATEs write coalesce(sum(...), 0) straight
-- into kitty_pools.total_collected/total_spent), so once those columns are
-- numeric(12,2) the existing, unmodified function bodies already carry
-- decimals through correctly. They are not recreated in this file.
--
-- Additive: six ALTER COLUMN TYPE statements (numeric(12,2) is always
-- reachable from integer via Postgres's built-in implicit cast, so no
-- USING clause is needed and no existing CHECK constraint is invalidated),
-- three function bodies rewritten to drop their now-incorrect
-- round(...)::integer coercions, and one RETURNS TABLE column retyped. No
-- table is dropped, no column removed, no row's value changes (every
-- existing integer amount becomes the numerically identical numeric value,
-- e.g. 500 -> 500.00).

-- ---------------------------------------------------------------------------
-- 1. Column type changes
-- ---------------------------------------------------------------------------
ALTER TABLE public.contributions ALTER COLUMN amount TYPE numeric(12,2);
ALTER TABLE public.kitty_expenses ALTER COLUMN amount TYPE numeric(12,2);
ALTER TABLE public.expenses ALTER COLUMN amount TYPE numeric(12,2);
ALTER TABLE public.events ALTER COLUMN contribution_amount TYPE numeric(12,2);

-- Direct consequence of the two columns above (see header): the running
-- accumulators record_contribution/record_expense write into and
-- get_kitty_balance reads back from.
ALTER TABLE public.kitty_pools ALTER COLUMN total_collected TYPE numeric(12,2);
ALTER TABLE public.kitty_pools ALTER COLUMN total_spent TYPE numeric(12,2);

COMMENT ON COLUMN public.contributions.amount IS
  'Contribution amount. numeric(12,2): paise/cents are preserved end to end, never rounded away.';
COMMENT ON COLUMN public.kitty_expenses.amount IS
  'Expense amount. numeric(12,2): paise/cents are preserved end to end, never rounded away.';
COMMENT ON COLUMN public.expenses.amount IS
  'Event/group bill amount. numeric(12,2): paise/cents are preserved end to end, never rounded away.';
COMMENT ON COLUMN public.events.contribution_amount IS
  'Advertised per-member contribution for the party. numeric(12,2): paise/cents are preserved.';
COMMENT ON COLUMN public.kitty_pools.total_collected IS
  'Running sum of non-voided contributions.amount. numeric(12,2) to match; see contributions.amount.';
COMMENT ON COLUMN public.kitty_pools.total_spent IS
  'Running sum of non-voided kitty_expenses.amount. numeric(12,2) to match; see kitty_expenses.amount.';

-- ---------------------------------------------------------------------------
-- 2. record_contribution — p_amount was already numeric; only the internal
--    round(...)::integer truncation and the accumulator write need fixing.
--    Current body re-read from 20260810120000_p14_rsvp_attendance_media_
--    purpose.sql (the latest CREATE OR REPLACE); signature is unchanged.
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
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = p_pool_id FOR UPDATE;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'Pool not found';
  END IF;
  IF NOT public.is_group_host(pool.group_id, uid) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;
  IF NOT public.is_group_member(pool.group_id, p_user_id)
     AND NOT public.is_group_host(pool.group_id, p_user_id) THEN
    RAISE EXCEPTION 'User is not a group member';
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
  'Host records a member contribution. Amount is numeric(12,2) end to end: no rounding to whole rupees.';

-- ---------------------------------------------------------------------------
-- 3. record_expense — p_amount integer -> numeric (signature change, so
--    drop then recreate, same as every other integer->numeric RPC change in
--    this codebase, e.g. P27's create_kitty_pool). Current body re-read from
--    20260810120000_p14_rsvp_attendance_media_purpose.sql.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.record_expense(uuid, integer, text, text, uuid, text);

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
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = p_pool_id FOR UPDATE;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'Pool not found';
  END IF;
  IF NOT public.is_group_host(pool.group_id, uid) THEN
    RAISE EXCEPTION 'Host access required';
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
  'Host records a kitty expense. Amount is numeric(12,2) end to end: no rounding to whole rupees.';

REVOKE ALL ON FUNCTION public.record_expense(uuid, numeric, text, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_expense(uuid, numeric, text, text, uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. confirm_ocr_expense — p_confirmed_amount was already numeric; only the
--    round(...)::integer truncation and the call into record_expense need
--    fixing to pass the numeric value straight through. Current body
--    re-read from 20260810120000_p14_rsvp_attendance_media_purpose.sql.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.confirm_ocr_expense(
  p_pool_id uuid,
  p_ocr_result jsonb DEFAULT '{}'::jsonb,
  p_confirmed_amount numeric DEFAULT NULL,
  p_confirmed_vendor text DEFAULT NULL,
  p_confirmed_category text DEFAULT NULL,
  p_receipt_media_id uuid DEFAULT NULL
) RETURNS public.kitty_expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  pool public.kitty_pools;
  ocr jsonb := coalesce(p_ocr_result, '{}'::jsonb);
  exp public.kitty_expenses;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF jsonb_typeof(ocr) <> 'object' THEN
    RAISE EXCEPTION 'OCR result must be a JSON object';
  END IF;
  IF p_confirmed_amount IS NULL OR p_confirmed_amount <= 0 THEN
    RAISE EXCEPTION 'Confirmed amount must be positive';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = p_pool_id;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'Pool not found';
  END IF;
  IF NOT public.is_group_host(pool.group_id, uid) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;

  -- Tag before ledger write so even a failed expense leaves receipt marked.
  PERFORM public.tag_media_as_receipt(p_receipt_media_id);

  exp := public.record_expense(
    p_pool_id,
    p_confirmed_amount,
    p_confirmed_vendor,
    p_confirmed_category,
    p_receipt_media_id,
    'ocr_confirmed'
  );

  RETURN exp;
END;
$$;

COMMENT ON FUNCTION public.confirm_ocr_expense(uuid, jsonb, numeric, text, text, uuid) IS
  'OCR->kitty_expenses path. Tags p_receipt_media_id as purpose=receipt automatically. Amount is numeric(12,2) end to end: no rounding to whole rupees.';

REVOKE ALL ON FUNCTION public.confirm_ocr_expense(uuid, jsonb, numeric, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_ocr_expense(uuid, jsonb, numeric, text, text, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. get_kitty_balance — same frozen contract, same signature. Remove the
--    three ::integer casts that would otherwise silently round paise back
--    off on every read; retype the two matching local variables. Current
--    body re-read in full from 20260823120000_p27_kitty_expected_per_member.sql
--    immediately before writing this — every other line (voided-row
--    filters, totals_consistent, members[] shape, KITPAT_* codes) is
--    reproduced byte-for-byte.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kitty_balance(
  p_pool_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  pool public.kitty_pools;
  live_collected numeric(12,2);
  live_spent numeric(12,2);
  voided_contributions integer;
  voided_expenses integer;
  result jsonb;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = p_pool_id;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
  IF NOT public.is_group_member(pool.group_id, uid)
     AND NOT public.is_group_host(pool.group_id, uid) THEN
    RAISE EXCEPTION 'KITPAT_NOT_MEMBER' USING ERRCODE = 'PT403';
  END IF;

  SELECT coalesce(sum(c.amount) FILTER (WHERE c.voided_at IS NULL), 0),
         count(*) FILTER (WHERE c.voided_at IS NOT NULL)::integer
    INTO live_collected, voided_contributions
  FROM public.contributions c
  WHERE c.pool_id = pool.id;

  SELECT coalesce(sum(e.amount) FILTER (WHERE e.voided_at IS NULL), 0),
         count(*) FILTER (WHERE e.voided_at IS NOT NULL)::integer
    INTO live_spent, voided_expenses
  FROM public.kitty_expenses e
  WHERE e.pool_id = pool.id;

  SELECT jsonb_build_object(
    'ok', true,
    'pool_id', pool.id,
    'group_id', pool.group_id,
    'month', pool.month,
    'expected_per_member', pool.expected_per_member,
    'collected', coalesce(pool.total_collected, 0),
    'spent', coalesce(pool.total_spent, 0),
    'balance', coalesce(pool.total_collected, 0) - coalesce(pool.total_spent, 0),
    -- false = kitty_pools totals disagree with the non-voided ledger rows.
    -- Money is still returned as a number; the frontend shows the warning.
    -- Additive diagnostic keys from P26, kept for backward compatibility;
    -- not part of the frozen contract documented in P27's migration header.
    'totals_consistent', (
      coalesce(pool.total_collected, 0) = live_collected
      AND coalesce(pool.total_spent, 0) = live_spent
    ),
    'voided_contributions', voided_contributions,
    'voided_expenses', voided_expenses,
    'members', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'user_id', x.user_id,
          'name', x.name,
          'amount_paid', x.amount_paid,
          'amount_pending', x.amount_pending,
          'status', CASE
            WHEN x.amount_pending = 0 AND x.amount_paid > 0 THEN 'paid'
            WHEN x.amount_paid > 0 AND x.amount_pending > 0 THEN 'partial'
            ELSE 'pending'
          END
        )
        ORDER BY x.joined_at
      )
      FROM (
        SELECT
          m.user_id,
          m.joined_at,
          -- The UI must never fall back to rendering a raw UUID.
          coalesce(u.name, 'Member') AS name,
          coalesce(c.paid_sum, 0) AS amount_paid,
          CASE
            WHEN pool.expected_per_member IS NULL THEN 0
            ELSE greatest(pool.expected_per_member - coalesce(c.paid_sum, 0), 0)
          END AS amount_pending
        FROM public.members m
        LEFT JOIN public.users u ON u.id = m.user_id
        LEFT JOIN (
          SELECT user_id, sum(amount) AS paid_sum
          FROM public.contributions
          WHERE pool_id = pool.id
            AND voided_at IS NULL
          GROUP BY user_id
        ) c ON c.user_id = m.user_id
        WHERE m.group_id = pool.group_id
      ) x
    ), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$$;

COMMENT ON FUNCTION public.get_kitty_balance(uuid) IS
  'Member/host read of a kitty pool. FROZEN CONTRACT for the frontend: ok, pool_id, group_id, month, expected_per_member, collected, spent, balance (all money keys always numbers, never null, now numeric(12,2)-precision), members[] with user_id, name, amount_paid, amount_pending, status. Do not rename or repurpose these fields in a future migration; add new keys instead. Excludes voided ledger rows (P26) everywhere. Raises KITPAT_UNAUTHENTICATED / KITPAT_NOT_FOUND / KITPAT_NOT_MEMBER on failure instead of ever returning a zero-shaped object.';

GRANT EXECUTE ON FUNCTION public.get_kitty_balance(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. n8n_events_due_in_24h — direct consequence of events.contribution_amount
--    changing type: RETURNS TABLE must match exactly. Logic is otherwise
--    byte-for-byte identical to 20260811010000_n8n_reminder_once.sql.
--
-- Postgres refuses CREATE OR REPLACE on a function whose RETURNS TABLE
-- column types change ("cannot change return type of existing function") --
-- unlike RETURNS public.sometable (a stable reference to the composite type
-- by name, unaffected by that table's own column changes), RETURNS TABLE
-- inlines the column types directly into the function's signature. This is
-- the only RETURNS TABLE function in this migration; every other rewritten
-- function here returns a named composite type or jsonb, neither of which
-- hits this restriction.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.n8n_events_due_in_24h();

CREATE OR REPLACE FUNCTION public.n8n_events_due_in_24h()
RETURNS TABLE (
  id uuid,
  group_id uuid,
  title text,
  theme text,
  venue text,
  party_date timestamptz,
  contribution_amount numeric(12,2),
  status text,
  group_name text,
  rsvp_going_maybe integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' AND auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  RETURN QUERY
  SELECT
    e.id,
    e.group_id,
    e.title,
    e.theme,
    e.venue,
    e.party_date,
    e.contribution_amount,
    e.status,
    g.name AS group_name,
    (
      SELECT count(*)::integer
      FROM public.rsvp r
      WHERE r.event_id = e.id
        AND r.status IN ('going', 'maybe')
    ) AS rsvp_going_maybe
  FROM public.events e
  JOIN public.groups g ON g.id = e.group_id
  WHERE e.status IN ('scheduled', 'live')
    AND e.party_date IS NOT NULL
    AND e.party_date >= now() - interval '1 hour'
    AND e.party_date < now() + interval '24 hours'
    AND NOT EXISTS (
      SELECT 1
      FROM public.sent_reminders sr
      WHERE sr.event_id = e.id
        AND sr.timing = '24h'
    )
  ORDER BY e.party_date ASC;
END;
$$;

COMMENT ON FUNCTION public.n8n_events_due_in_24h() IS
  'n8n: events in ~24h window that have not yet received a timing=24h reminder.';

GRANT EXECUTE ON FUNCTION public.n8n_events_due_in_24h() TO service_role, authenticated;
