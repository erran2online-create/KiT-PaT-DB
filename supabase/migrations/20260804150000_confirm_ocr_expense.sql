-- P5: Host-confirm path from OCR review → kitty_expenses.
-- OCR parsers/edge functions must NEVER insert expenses directly.
-- Only this RPC (after host Confirm) writes, via record_expense.

CREATE OR REPLACE FUNCTION public.confirm_ocr_expense(
  p_pool_id uuid,
  p_ocr_result jsonb,
  p_confirmed_amount integer,
  p_confirmed_vendor text,
  p_confirmed_category text,
  p_receipt_media_id uuid DEFAULT NULL
) RETURNS public.kitty_expenses
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
  if p_ocr_result is null or jsonb_typeof(p_ocr_result) <> 'object' then
    raise exception 'OCR result required';
  end if;
  if p_confirmed_amount is null or p_confirmed_amount <= 0 then
    raise exception 'Confirmed amount must be positive';
  end if;

  select * into pool from public.kitty_pools where id = p_pool_id;
  if pool.id is null then
    raise exception 'Pool not found';
  end if;
  if not public.is_group_host(pool.group_id, uid) then
    raise exception 'Host access required';
  end if;

  -- Write ONLY host-confirmed fields. Raw OCR amounts/vendors in p_ocr_result
  -- are review context for the client and must not drive the insert.
  return public.record_expense(
    p_pool_id,
    p_confirmed_amount,
    p_confirmed_vendor,
    p_confirmed_category,
    p_receipt_media_id,
    'ocr_confirmed'
  );
end;
$$;

COMMENT ON FUNCTION public.confirm_ocr_expense(uuid, jsonb, integer, text, text, uuid) IS
  'Sole OCR→kitty_expenses path. Host confirms corrected fields; calls record_expense. Never inserts from raw OCR values.';

REVOKE ALL ON FUNCTION public.confirm_ocr_expense(uuid, jsonb, integer, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_ocr_expense(uuid, jsonb, integer, text, text, uuid)
  TO authenticated, service_role;
