-- P27: expected_per_member on kitty_pools + frozen get_kitty_balance contract.
--
-- Before this migration get_kitty_balance() could tell a host how much has
-- been collected and who has paid something, but not how much any member is
-- SUPPOSED to pay, so "who still owes" had no answer: a member who paid ₹1
-- of a ₹2000 share read exactly the same as a member who paid in full.
--
-- This migration:
--   1. Adds kitty_pools.expected_per_member (nullable integer, no default —
--      existing pools keep answering "no target set" until a host sets one).
--   2. create_kitty_pool() takes it as an optional third argument.
--   3. Adds set_pool_expected(p_pool_id, p_amount) — host-only — to set or
--      change the target on an existing pool without recreating it.
--   4. Rewrites get_kitty_balance() to add expected_per_member, per-member
--      amount_pending and name, and a three-way status (paid/partial/pending)
--      to the OUTPUT DOCUMENTED BELOW. This is now the frozen shape the
--      frontend is told to depend on:
--
--        {
--          ok: true,
--          pool_id, group_id, month,
--          expected_per_member: integer|null,
--          collected: integer,   -- never null; 0 means no activity
--          spent: integer,       -- never null
--          balance: integer,     -- never null
--          members: [ { user_id, name, amount_paid: integer,
--                       amount_pending: integer,
--                       status: 'paid'|'partial'|'pending' } ]
--        }
--
--      These field names and meanings must not be renamed or repurposed by a
--      future migration; add new keys instead. The P26 diagnostic keys
--      (totals_consistent, voided_contributions, voided_expenses) are kept
--      alongside this contract for backward compatibility with the existing
--      P26 test and any caller already reading them — they are additive,
--      not part of the frozen shape above.
--
-- amount_pending = greatest(expected_per_member - amount_paid, 0), or 0 when
-- expected_per_member is null (no target set = nothing to be "pending" on).
-- status: 'paid' when pending = 0 and paid > 0; 'partial' when paid > 0 and
-- pending > 0; otherwise 'pending'. Voided contributions/expenses (P26) are
-- excluded from every sum exactly as before.
--
-- Additive only: one new nullable column with a CHECK that only constrains
-- non-null values, one new function, one CREATE OR REPLACE of an existing
-- read RPC, and create_kitty_pool is dropped and recreated with an extra
-- DEFAULT NULL argument so existing 2-argument callers are unaffected. No
-- existing row changes value; expected_per_member is null for every pool
-- until a host explicitly sets it.

-- ---------------------------------------------------------------------------
-- 1. kitty_pools.expected_per_member
-- ---------------------------------------------------------------------------
ALTER TABLE public.kitty_pools
  ADD COLUMN IF NOT EXISTS expected_per_member integer;

ALTER TABLE public.kitty_pools DROP CONSTRAINT IF EXISTS kitty_pools_expected_positive;
ALTER TABLE public.kitty_pools
  ADD CONSTRAINT kitty_pools_expected_positive
  CHECK (expected_per_member IS NULL OR expected_per_member > 0);

COMMENT ON COLUMN public.kitty_pools.expected_per_member IS
  'Target contribution per member for this pool, in the same integer currency unit as amount columns. NULL = no target set (get_kitty_balance reports amount_pending = 0 for every member in that case). Set at creation via create_kitty_pool() or later via set_pool_expected().';

-- ---------------------------------------------------------------------------
-- 2. create_kitty_pool — add optional p_expected_per_member
-- ---------------------------------------------------------------------------
-- Signature is changing (2 args -> 3 args with a default), so the old
-- 2-argument function must be dropped first: leaving both overloaded would
-- make PostgREST's 2-argument RPC calls ambiguous.
DROP FUNCTION IF EXISTS public.create_kitty_pool(uuid, text);

CREATE OR REPLACE FUNCTION public.create_kitty_pool(
  p_group_id uuid,
  p_month text,
  p_expected_per_member integer DEFAULT NULL
) RETURNS public.kitty_pools
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  uid uuid := auth.uid();
  pool public.kitty_pools;
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if p_month is null or p_month !~ '^\d{4}-\d{2}$' then
    raise exception 'Invalid month; expected YYYY-MM';
  end if;
  if not public.is_group_host(p_group_id, uid) then
    raise exception 'Host access required';
  end if;
  if p_expected_per_member is not null and p_expected_per_member <= 0 then
    raise exception 'KITPAT_INVALID_AMOUNT' using errcode = 'PT400';
  end if;

  insert into public.kitty_pools as kp (group_id, month, expected_per_member)
  values (p_group_id, p_month, p_expected_per_member)
  on conflict (group_id, month) do update
    set group_id = excluded.group_id,
        -- Re-running create for an existing month without specifying a
        -- target must not blow away a target set earlier.
        expected_per_member = coalesce(excluded.expected_per_member, kp.expected_per_member)
  returning * into pool;

  return pool;
end;
$$;

COMMENT ON FUNCTION public.create_kitty_pool(uuid, text, integer) IS
  'Host-only. Creates (or re-fetches) the pool for group_id/month. p_expected_per_member is optional; omitting it on an existing pool preserves whatever target was set before. Errors: KITPAT_INVALID_AMOUNT for a non-positive target.';

-- ---------------------------------------------------------------------------
-- 3. set_pool_expected — host-only, change the target on an existing pool
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_pool_expected(
  p_pool_id uuid,
  p_amount integer
) RETURNS public.kitty_pools
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  pool public.kitty_pools;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;
  IF p_amount IS NOT NULL AND p_amount <= 0 THEN
    RAISE EXCEPTION 'KITPAT_INVALID_AMOUNT' USING ERRCODE = 'PT400';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = p_pool_id FOR UPDATE;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
  IF NOT public.is_group_host(pool.group_id, uid) THEN
    RAISE EXCEPTION 'KITPAT_NOT_HOST' USING ERRCODE = 'PT403';
  END IF;

  UPDATE public.kitty_pools
  SET expected_per_member = p_amount
  WHERE id = pool.id
  RETURNING * INTO pool;

  RETURN pool;
END;
$$;

COMMENT ON FUNCTION public.set_pool_expected(uuid, integer) IS
  'Host-only. Sets (or, passed NULL, clears) kitty_pools.expected_per_member for an existing pool. Errors: KITPAT_UNAUTHENTICATED / KITPAT_INVALID_AMOUNT / KITPAT_NOT_FOUND / KITPAT_NOT_HOST.';

-- ---------------------------------------------------------------------------
-- 4. get_kitty_balance — frozen contract (see header)
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
    -- not part of the frozen contract documented in this migration's header.
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
          SELECT user_id, sum(amount)::integer AS paid_sum
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
  'Member/host read of a kitty pool. FROZEN CONTRACT for the frontend: ok, pool_id, group_id, month, expected_per_member, collected, spent, balance (all money keys always numbers, never null), members[] with user_id, name, amount_paid, amount_pending, status. Do not rename or repurpose these fields in a future migration; add new keys instead. Excludes voided ledger rows (P26) everywhere. Raises KITPAT_UNAUTHENTICATED / KITPAT_NOT_FOUND / KITPAT_NOT_MEMBER on failure instead of ever returning a zero-shaped object.';

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.create_kitty_pool(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_pool_expected(uuid, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_kitty_pool(uuid, text, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_pool_expected(uuid, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_kitty_balance(uuid) TO authenticated, service_role;
