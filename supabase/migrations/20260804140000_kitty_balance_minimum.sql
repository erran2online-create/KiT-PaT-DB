-- P4: Minimum Kitty Balance backend
-- Note: public.expenses already exists (event/group bill tracker). Pool expenses
-- live in public.kitty_expenses to avoid colliding with that table.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kitty_pools (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  month text NOT NULL,
  total_collected integer NOT NULL DEFAULT 0,
  total_spent integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kitty_pools_month_format CHECK (month ~ '^\d{4}-\d{2}$'),
  CONSTRAINT kitty_pools_collected_nonneg CHECK (total_collected >= 0),
  CONSTRAINT kitty_pools_spent_nonneg CHECK (total_spent >= 0),
  CONSTRAINT kitty_pools_group_month_key UNIQUE (group_id, month)
);

CREATE TABLE IF NOT EXISTS public.contributions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pool_id uuid NOT NULL REFERENCES public.kitty_pools(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.users(id),
  amount integer NOT NULL,
  paid_at timestamptz NOT NULL DEFAULT now(),
  method text,
  CONSTRAINT contributions_amount_positive CHECK (amount > 0)
);

CREATE TABLE IF NOT EXISTS public.kitty_expenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pool_id uuid NOT NULL REFERENCES public.kitty_pools(id) ON DELETE CASCADE,
  added_by uuid NOT NULL REFERENCES public.users(id),
  amount integer NOT NULL,
  vendor text,
  category text,
  receipt_media_id uuid REFERENCES public.media(id) ON DELETE SET NULL,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kitty_expenses_amount_positive CHECK (amount > 0)
);

CREATE INDEX IF NOT EXISTS idx_kitty_pools_group ON public.kitty_pools (group_id);
CREATE INDEX IF NOT EXISTS idx_contributions_pool ON public.contributions (pool_id);
CREATE INDEX IF NOT EXISTS idx_contributions_user ON public.contributions (user_id);
CREATE INDEX IF NOT EXISTS idx_kitty_expenses_pool ON public.kitty_expenses (pool_id);

COMMENT ON TABLE public.kitty_pools IS 'Monthly kitty pool per group. totals maintained by record_* RPCs.';
COMMENT ON TABLE public.contributions IS 'Member contributions into a kitty pool.';
COMMENT ON TABLE public.kitty_expenses IS 'Pool expenses for Kitty Balance (distinct from public.expenses event bills).';

-- ---------------------------------------------------------------------------
-- 2. RLS — members may read; writes only via SECURITY DEFINER RPCs
-- ---------------------------------------------------------------------------
ALTER TABLE public.kitty_pools ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kitty_expenses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS kitty_pools_read_members ON public.kitty_pools;
CREATE POLICY kitty_pools_read_members ON public.kitty_pools
  FOR SELECT TO authenticated
  USING (
    public.is_group_member(group_id, (SELECT auth.uid()))
    OR public.is_group_host(group_id, (SELECT auth.uid()))
  );

DROP POLICY IF EXISTS contributions_read_members ON public.contributions;
CREATE POLICY contributions_read_members ON public.contributions
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.kitty_pools p
      WHERE p.id = pool_id
        AND (
          public.is_group_member(p.group_id, (SELECT auth.uid()))
          OR public.is_group_host(p.group_id, (SELECT auth.uid()))
        )
    )
  );

DROP POLICY IF EXISTS kitty_expenses_read_members ON public.kitty_expenses;
CREATE POLICY kitty_expenses_read_members ON public.kitty_expenses
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.kitty_pools p
      WHERE p.id = pool_id
        AND (
          public.is_group_member(p.group_id, (SELECT auth.uid()))
          OR public.is_group_host(p.group_id, (SELECT auth.uid()))
        )
    )
  );

REVOKE ALL ON TABLE public.kitty_pools FROM anon;
REVOKE ALL ON TABLE public.contributions FROM anon;
REVOKE ALL ON TABLE public.kitty_expenses FROM anon;

GRANT SELECT ON TABLE public.kitty_pools TO authenticated;
GRANT SELECT ON TABLE public.contributions TO authenticated;
GRANT SELECT ON TABLE public.kitty_expenses TO authenticated;
GRANT ALL ON TABLE public.kitty_pools TO service_role;
GRANT ALL ON TABLE public.contributions TO service_role;
GRANT ALL ON TABLE public.kitty_expenses TO service_role;

-- ---------------------------------------------------------------------------
-- 3. create_kitty_pool — host-only helper (minimum create path)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_kitty_pool(
  p_group_id uuid,
  p_month text
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

  insert into public.kitty_pools (group_id, month)
  values (p_group_id, p_month)
  on conflict (group_id, month) do update
    set group_id = excluded.group_id
  returning * into pool;

  return pool;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. record_contribution — host-only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_contribution(
  p_pool_id uuid,
  p_user_id uuid,
  p_amount integer,
  p_method text DEFAULT NULL
) RETURNS public.contributions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  uid uuid := auth.uid();
  pool public.kitty_pools;
  contrib public.contributions;
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be positive';
  end if;

  select * into pool from public.kitty_pools where id = p_pool_id for update;
  if pool.id is null then
    raise exception 'Pool not found';
  end if;
  if not public.is_group_host(pool.group_id, uid) then
    raise exception 'Host access required';
  end if;
  if not public.is_group_member(pool.group_id, p_user_id)
     and not public.is_group_host(pool.group_id, p_user_id) then
    raise exception 'User is not a group member';
  end if;

  insert into public.contributions (pool_id, user_id, amount, method, paid_at)
  values (p_pool_id, p_user_id, p_amount, p_method, now())
  returning * into contrib;

  update public.kitty_pools
  set total_collected = total_collected + p_amount
  where id = p_pool_id;

  return contrib;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. record_expense — host-only (writes kitty_expenses)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_expense(
  p_pool_id uuid,
  p_amount integer,
  p_vendor text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_receipt_media_id uuid DEFAULT NULL,
  p_note text DEFAULT NULL
) RETURNS public.kitty_expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  uid uuid := auth.uid();
  pool public.kitty_pools;
  exp public.kitty_expenses;
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be positive';
  end if;

  select * into pool from public.kitty_pools where id = p_pool_id for update;
  if pool.id is null then
    raise exception 'Pool not found';
  end if;
  if not public.is_group_host(pool.group_id, uid) then
    raise exception 'Host access required';
  end if;

  insert into public.kitty_expenses (
    pool_id, added_by, amount, vendor, category, receipt_media_id, note
  ) values (
    p_pool_id, uid, p_amount, p_vendor, p_category, p_receipt_media_id, p_note
  ) returning * into exp;

  update public.kitty_pools
  set total_spent = total_spent + p_amount
  where id = p_pool_id;

  return exp;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. get_kitty_balance — any group member
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kitty_balance(
  p_pool_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  uid uuid := auth.uid();
  pool public.kitty_pools;
  result jsonb;
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;

  select * into pool from public.kitty_pools where id = p_pool_id;
  if pool.id is null then
    raise exception 'Pool not found';
  end if;
  if not public.is_group_member(pool.group_id, uid)
     and not public.is_group_host(pool.group_id, uid) then
    raise exception 'Group membership required';
  end if;

  select jsonb_build_object(
    'pool_id', pool.id,
    'group_id', pool.group_id,
    'month', pool.month,
    'collected', pool.total_collected,
    'spent', pool.total_spent,
    'balance', pool.total_collected - pool.total_spent,
    'members', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'user_id', m.user_id,
          'amount_paid', coalesce(c.paid_sum, 0),
          'status', case when coalesce(c.paid_sum, 0) > 0 then 'paid' else 'pending' end
        )
        order by m.joined_at
      )
      from public.members m
      left join (
        select user_id, sum(amount)::integer as paid_sum
        from public.contributions
        where pool_id = pool.id
        group by user_id
      ) c on c.user_id = m.user_id
      where m.group_id = pool.group_id
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

REVOKE ALL ON FUNCTION public.create_kitty_pool(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_contribution(uuid, uuid, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.record_expense(uuid, integer, text, text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_kitty_balance(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_kitty_pool(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_contribution(uuid, uuid, integer, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.record_expense(uuid, integer, text, text, uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_kitty_balance(uuid) TO authenticated, service_role;
