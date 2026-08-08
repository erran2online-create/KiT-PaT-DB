-- P9.4: Lovable always calls record_contribution with p_note (+ optional
-- receipt media). Missing p_note → PostgREST PGRST202 ("Could not find the
-- function ... p_note ..."), which surfaces as a generic contribution error.
-- Also accept numeric amounts (OCR autofill / JS Number) like confirm_ocr_expense.

ALTER TABLE public.contributions
  ADD COLUMN IF NOT EXISTS note text;

COMMENT ON COLUMN public.contributions.note IS
  'Optional host note from the contribution form (frontend p_note).';

DROP FUNCTION IF EXISTS public.record_contribution(uuid, uuid, integer, text, uuid);

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
declare
  uid uuid := auth.uid();
  pool public.kitty_pools;
  contrib public.contributions;
  amount_int integer;
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be positive';
  end if;

  amount_int := round(p_amount)::integer;
  if amount_int <= 0 then
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
    pool_id, user_id, amount, method, paid_at, receipt_media_id, note
  ) values (
    p_pool_id, p_user_id, amount_int, p_method, now(), p_receipt_media_id, p_note
  )
  returning * into contrib;

  update public.kitty_pools
  set total_collected = total_collected + amount_int
  where id = p_pool_id;

  return contrib;
end;
$$;

COMMENT ON FUNCTION public.record_contribution(uuid, uuid, numeric, text, text, uuid) IS
  'Host records a member contribution; accepts p_note + p_receipt_media_id as Lovable sends.';

REVOKE ALL ON FUNCTION public.record_contribution(uuid, uuid, numeric, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_contribution(uuid, uuid, numeric, text, text, uuid)
  TO authenticated, service_role;
