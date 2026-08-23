-- P26: Kitty ledger soft delete.
--
-- Before this migration the frontend "removed" a contribution / kitty expense
-- with a raw client-side DELETE. That can never work and never worked:
-- contributions and kitty_expenses have RLS enabled with a SELECT-only policy
-- and no DELETE policy at all, so PostgREST returns 204 with zero rows removed
-- while the pool totals stay untouched. The ledger silently disagreed with the
-- UI. Worse, the tables still carry Supabase's default table-level DELETE and
-- TRUNCATE grants to authenticated (only RLS was standing in the way, and
-- TRUNCATE is not subject to RLS at all).
--
-- This migration replaces that path with host-only soft delete:
--   * voided_at / voided_by / void_reason on both ledger tables
--   * void_contribution() / void_kitty_expense() SECURITY DEFINER RPCs that
--     mark the row voided AND re-settle the pool total in the same transaction
--   * get_kitty_balance() ignores voided rows
--   * DELETE + TRUNCATE revoked from authenticated (and anon) on both tables
--
-- Additive only: new nullable columns, new functions, one CREATE OR REPLACE of
-- an existing read RPC. No data is rewritten, nothing is dropped, no existing
-- row changes value.
--
-- Pool totals are re-settled by RECOMPUTING from the non-voided rows of that
-- pool rather than by a blind `total - amount`. In a consistent pool the two
-- are identical (the void drops the total by exactly the voided amount); the
-- recompute additionally makes drift between kitty_pools.total_* and
-- sum(non-voided ledger rows) impossible to create, which is what the P26
-- invariant test asserts. Verified against the live pools before writing this:
-- all four pools were already exactly consistent, so no pool changes value
-- until it is actually voided against.

-- ---------------------------------------------------------------------------
-- 1. Soft-delete columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.contributions
  ADD COLUMN IF NOT EXISTS voided_at timestamptz,
  ADD COLUMN IF NOT EXISTS voided_by uuid REFERENCES public.users(id),
  ADD COLUMN IF NOT EXISTS void_reason text;

ALTER TABLE public.kitty_expenses
  ADD COLUMN IF NOT EXISTS voided_at timestamptz,
  ADD COLUMN IF NOT EXISTS voided_by uuid REFERENCES public.users(id),
  ADD COLUMN IF NOT EXISTS void_reason text;

COMMENT ON COLUMN public.contributions.voided_at IS
  'Set by void_contribution(). Non-null = row is cancelled and excluded from every kitty total. Rows are never hard-deleted.';
COMMENT ON COLUMN public.contributions.voided_by IS
  'Host (users.id) who voided the row.';
COMMENT ON COLUMN public.contributions.void_reason IS
  'Optional host-supplied reason captured at void time.';

COMMENT ON COLUMN public.kitty_expenses.voided_at IS
  'Set by void_kitty_expense(). Non-null = row is cancelled and excluded from every kitty total. Rows are never hard-deleted.';
COMMENT ON COLUMN public.kitty_expenses.voided_by IS
  'Host (users.id) who voided the row.';
COMMENT ON COLUMN public.kitty_expenses.void_reason IS
  'Optional host-supplied reason captured at void time.';

-- Live-ledger reads are always "non-voided rows of this pool".
CREATE INDEX IF NOT EXISTS idx_contributions_pool_live
  ON public.contributions (pool_id)
  WHERE voided_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_kitty_expenses_pool_live
  ON public.kitty_expenses (pool_id)
  WHERE voided_at IS NULL;

-- ---------------------------------------------------------------------------
-- 2. void_contribution — host of the pool's group only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_contribution(
  p_contribution_id uuid,
  p_reason text DEFAULT NULL
) RETURNS public.contributions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  v_pool_id uuid;
  pool public.kitty_pools;
  row public.contributions;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;
  IF p_contribution_id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  -- Lock the pool before the ledger row: record_contribution() takes the pool
  -- lock first too, so both paths acquire locks in the same order.
  SELECT c.pool_id INTO v_pool_id
  FROM public.contributions c
  WHERE c.id = p_contribution_id;

  IF v_pool_id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = v_pool_id FOR UPDATE;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  IF NOT public.is_group_host(pool.group_id, uid) THEN
    RAISE EXCEPTION 'KITPAT_NOT_HOST' USING ERRCODE = 'PT403';
  END IF;

  SELECT * INTO row
  FROM public.contributions
  WHERE id = p_contribution_id
  FOR UPDATE;

  IF row.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
  IF row.voided_at IS NOT NULL THEN
    RAISE EXCEPTION 'KITPAT_ALREADY_VOIDED' USING ERRCODE = 'PT409';
  END IF;

  UPDATE public.contributions c
  SET voided_at = now(),
      voided_by = uid,
      void_reason = nullif(btrim(coalesce(p_reason, '')), '')
  WHERE c.id = row.id
    AND c.voided_at IS NULL
  RETURNING * INTO row;

  IF row.id IS NULL THEN
    -- Lost a concurrent race for the same row.
    RAISE EXCEPTION 'KITPAT_ALREADY_VOIDED' USING ERRCODE = 'PT409';
  END IF;

  -- Same transaction: re-settle the pool from the surviving rows.
  UPDATE public.kitty_pools p
  SET total_collected = coalesce((
        SELECT sum(c.amount)
        FROM public.contributions c
        WHERE c.pool_id = p.id
          AND c.voided_at IS NULL
      ), 0)
  WHERE p.id = pool.id;

  RETURN row;
END;
$$;

COMMENT ON FUNCTION public.void_contribution(uuid, text) IS
  'Host-only soft delete of a contribution. Marks voided_at/voided_by/void_reason and re-settles kitty_pools.total_collected in the same transaction. Never hard-deletes. Errors: KITPAT_UNAUTHENTICATED / KITPAT_NOT_FOUND / KITPAT_NOT_HOST / KITPAT_ALREADY_VOIDED.';

-- ---------------------------------------------------------------------------
-- 3. void_kitty_expense — host of the pool's group only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_kitty_expense(
  p_expense_id uuid,
  p_reason text DEFAULT NULL
) RETURNS public.kitty_expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  v_pool_id uuid;
  pool public.kitty_pools;
  row public.kitty_expenses;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;
  IF p_expense_id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  SELECT e.pool_id INTO v_pool_id
  FROM public.kitty_expenses e
  WHERE e.id = p_expense_id;

  IF v_pool_id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = v_pool_id FOR UPDATE;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  IF NOT public.is_group_host(pool.group_id, uid) THEN
    RAISE EXCEPTION 'KITPAT_NOT_HOST' USING ERRCODE = 'PT403';
  END IF;

  SELECT * INTO row
  FROM public.kitty_expenses
  WHERE id = p_expense_id
  FOR UPDATE;

  IF row.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
  IF row.voided_at IS NOT NULL THEN
    RAISE EXCEPTION 'KITPAT_ALREADY_VOIDED' USING ERRCODE = 'PT409';
  END IF;

  UPDATE public.kitty_expenses e
  SET voided_at = now(),
      voided_by = uid,
      void_reason = nullif(btrim(coalesce(p_reason, '')), '')
  WHERE e.id = row.id
    AND e.voided_at IS NULL
  RETURNING * INTO row;

  IF row.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_ALREADY_VOIDED' USING ERRCODE = 'PT409';
  END IF;

  UPDATE public.kitty_pools p
  SET total_spent = coalesce((
        SELECT sum(e.amount)
        FROM public.kitty_expenses e
        WHERE e.pool_id = p.id
          AND e.voided_at IS NULL
      ), 0)
  WHERE p.id = pool.id;

  RETURN row;
END;
$$;

COMMENT ON FUNCTION public.void_kitty_expense(uuid, text) IS
  'Host-only soft delete of a kitty expense. Marks voided_at/voided_by/void_reason and re-settles kitty_pools.total_spent in the same transaction. Never hard-deletes. Errors: KITPAT_UNAUTHENTICATED / KITPAT_NOT_FOUND / KITPAT_NOT_HOST / KITPAT_ALREADY_VOIDED.';

-- ---------------------------------------------------------------------------
-- 4. get_kitty_balance — ignore voided rows
-- ---------------------------------------------------------------------------
-- Same shape as before plus two additive keys: totals_consistent (money flag,
-- never null) and voided_count. Per-member amount_paid now sums non-voided
-- contributions only, so a voided row can no longer keep a member "paid".
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
  live_collected integer;
  live_spent integer;
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

  SELECT coalesce(sum(c.amount) FILTER (WHERE c.voided_at IS NULL), 0)::integer,
         count(*) FILTER (WHERE c.voided_at IS NOT NULL)::integer
    INTO live_collected, voided_contributions
  FROM public.contributions c
  WHERE c.pool_id = pool.id;

  SELECT coalesce(sum(e.amount) FILTER (WHERE e.voided_at IS NULL), 0)::integer,
         count(*) FILTER (WHERE e.voided_at IS NOT NULL)::integer
    INTO live_spent, voided_expenses
  FROM public.kitty_expenses e
  WHERE e.pool_id = pool.id;

  SELECT jsonb_build_object(
    'pool_id', pool.id,
    'group_id', pool.group_id,
    'month', pool.month,
    'collected', coalesce(pool.total_collected, 0),
    'spent', coalesce(pool.total_spent, 0),
    'balance', coalesce(pool.total_collected, 0) - coalesce(pool.total_spent, 0),
    -- false = kitty_pools totals disagree with the non-voided ledger rows.
    -- Money is still returned as a number; the frontend shows the warning.
    'totals_consistent', (
      coalesce(pool.total_collected, 0) = live_collected
      AND coalesce(pool.total_spent, 0) = live_spent
    ),
    'voided_contributions', voided_contributions,
    'voided_expenses', voided_expenses,
    'members', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'user_id', m.user_id,
          'amount_paid', coalesce(c.paid_sum, 0),
          'status', CASE WHEN coalesce(c.paid_sum, 0) > 0 THEN 'paid' ELSE 'pending' END
        )
        ORDER BY m.joined_at
      )
      FROM public.members m
      LEFT JOIN (
        SELECT user_id, sum(amount)::integer AS paid_sum
        FROM public.contributions
        WHERE pool_id = pool.id
          AND voided_at IS NULL
        GROUP BY user_id
      ) c ON c.user_id = m.user_id
      WHERE m.group_id = pool.group_id
    ), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$$;

COMMENT ON FUNCTION public.get_kitty_balance(uuid) IS
  'Member/host read of a kitty pool. Excludes voided ledger rows everywhere; adds totals_consistent + voided_* counts. Money keys are always numbers, never null.';

-- ---------------------------------------------------------------------------
-- 5. Deletion is only possible through the void RPCs
-- ---------------------------------------------------------------------------
-- authenticated still carried Supabase's default DELETE/TRUNCATE grants on
-- both ledger tables; only RLS (no DELETE policy) was blocking the delete, and
-- TRUNCATE bypasses RLS entirely. Both go.
REVOKE DELETE, TRUNCATE ON TABLE public.contributions FROM authenticated;
REVOKE DELETE, TRUNCATE ON TABLE public.kitty_expenses FROM authenticated;
REVOKE DELETE, TRUNCATE ON TABLE public.contributions FROM anon;
REVOKE DELETE, TRUNCATE ON TABLE public.kitty_expenses FROM anon;

-- No DELETE policy is added: with the privilege gone, a client DELETE fails
-- with 42501 instead of silently affecting zero rows.

REVOKE ALL ON FUNCTION public.void_contribution(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.void_kitty_expense(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.void_contribution(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.void_kitty_expense(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_kitty_balance(uuid) TO authenticated, service_role;
