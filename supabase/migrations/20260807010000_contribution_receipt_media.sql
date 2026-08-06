-- P9.3: Link contribution screenshots to contributions rows.
-- kitty_expenses.pool_id already exists (P4) — confirmed present; no change needed.

ALTER TABLE public.contributions
  ADD COLUMN IF NOT EXISTS receipt_media_id uuid REFERENCES public.media(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.contributions.receipt_media_id IS
  'Optional payment screenshot / proof media, same pattern as kitty_expenses.receipt_media_id.';

CREATE INDEX IF NOT EXISTS idx_contributions_receipt_media
  ON public.contributions (receipt_media_id)
  WHERE receipt_media_id IS NOT NULL;

-- New optional arg → drop old 4-arg overload so PostgREST resolves the updated signature.
DROP FUNCTION IF EXISTS public.record_contribution(uuid, uuid, integer, text);

CREATE OR REPLACE FUNCTION public.record_contribution(
  p_pool_id uuid,
  p_user_id uuid,
  p_amount integer,
  p_method text DEFAULT NULL,
  p_receipt_media_id uuid DEFAULT NULL
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

  insert into public.contributions (
    pool_id, user_id, amount, method, paid_at, receipt_media_id
  ) values (
    p_pool_id, p_user_id, p_amount, p_method, now(), p_receipt_media_id
  )
  returning * into contrib;

  update public.kitty_pools
  set total_collected = total_collected + p_amount
  where id = p_pool_id;

  return contrib;
end;
$$;

COMMENT ON FUNCTION public.record_contribution(uuid, uuid, integer, text, uuid) IS
  'Host records a member contribution; optional p_receipt_media_id stores payment proof.';

REVOKE ALL ON FUNCTION public.record_contribution(uuid, uuid, integer, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_contribution(uuid, uuid, integer, text, uuid)
  TO authenticated, service_role;
