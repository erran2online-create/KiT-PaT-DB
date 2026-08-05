-- P8.2: Lovable confirm_ocr_expense sends p_ocr_result: null when the host
-- confirms a receipt without a prior OCR parse. The original RPC rejected null
-- with "OCR result required", which the frontend surfaces as a generic error.
-- Also accept numeric amounts (inputMode=decimal → JSON 450.0) and coerce to int.

DROP FUNCTION IF EXISTS public.confirm_ocr_expense(uuid, jsonb, integer, text, text, uuid);

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
declare
  uid uuid := auth.uid();
  pool public.kitty_pools;
  ocr jsonb := coalesce(p_ocr_result, '{}'::jsonb);
  amount_int integer;
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if jsonb_typeof(ocr) <> 'object' then
    raise exception 'OCR result must be a JSON object';
  end if;
  if p_confirmed_amount is null or p_confirmed_amount <= 0 then
    raise exception 'Confirmed amount must be positive';
  end if;

  -- Whole rupees for kitty ledger; round so decimal inputMode doesn't 22P02.
  amount_int := round(p_confirmed_amount)::integer;
  if amount_int <= 0 then
    raise exception 'Confirmed amount must be positive';
  end if;

  select * into pool from public.kitty_pools where id = p_pool_id;
  if pool.id is null then
    raise exception 'Pool not found';
  end if;
  if not public.is_group_host(pool.group_id, uid) then
    raise exception 'Host access required';
  end if;

  -- Write ONLY host-confirmed fields. Raw OCR in p_ocr_result is review
  -- context and must not drive the insert (empty {} is fine for manual entry).
  return public.record_expense(
    p_pool_id,
    amount_int,
    p_confirmed_vendor,
    p_confirmed_category,
    p_receipt_media_id,
    'ocr_confirmed'
  );
end;
$$;

COMMENT ON FUNCTION public.confirm_ocr_expense(uuid, jsonb, numeric, text, text, uuid) IS
  'Sole OCR→kitty_expenses path. Host confirms corrected fields; null/omitted OCR ok (manual bill). Calls record_expense.';

REVOKE ALL ON FUNCTION public.confirm_ocr_expense(uuid, jsonb, numeric, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_ocr_expense(uuid, jsonb, numeric, text, text, uuid)
  TO authenticated, service_role;
