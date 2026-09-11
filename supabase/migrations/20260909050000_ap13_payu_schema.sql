-- ---------------------------------------------------------------------------
-- AP13: PayU (India) schema groundwork -- ONLY what is identical under
-- either PayU integration route (Zion automation vs full API). The
-- recurring-mandate mechanics are NOT decided yet, so this migration adds
-- NO charge, mandate or checkout logic of any kind -- plan id columns for
-- the gateway to reference, and a provider-agnostic webhook/callback log.
-- Razorpay stays fully in place as a fallback until PayU is live:
-- razorpay_plan_id_monthly/yearly, razorpay_events, razorpay-create-order,
-- subscriptions, and every existing policy are untouched.
--
-- payment_events mirrors razorpay_events' existing shape (id, event_type,
-- <provider>_event_id, payload, created_at -- read from
-- 20260801140136_remote_schema.sql before writing this, not assumed) but
-- generalized to carry a provider column and the extra fields both
-- Razorpay and PayU webhooks actually carry (a transaction id, our own
-- merchant-generated transaction id, the subject user/subscription,
-- amount/currency/status, and whether the signature was verified).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. plans -- PayU plan ids alongside the existing Razorpay ones.
-- ---------------------------------------------------------------------------
ALTER TABLE public.plans
  ADD COLUMN IF NOT EXISTS payu_plan_id_monthly text,
  ADD COLUMN IF NOT EXISTS payu_plan_id_yearly text;

COMMENT ON COLUMN public.plans.payu_plan_id_monthly IS
  'PayU-side plan identifier for the monthly cycle. NULL until PayU is configured. razorpay_plan_id_monthly stays in place as a fallback until PayU is live -- this is additive, not a replacement.';
COMMENT ON COLUMN public.plans.payu_plan_id_yearly IS
  'PayU-side plan identifier for the yearly cycle. NULL until PayU is configured. razorpay_plan_id_yearly stays in place as a fallback until PayU is live -- this is additive, not a replacement.';

-- ---------------------------------------------------------------------------
-- 2. payment_events -- provider webhook/callback log. service_role only:
--    no client policy of any kind. A member must never see raw gateway
--    payloads (which can carry cardholder-adjacent fragments), and an
--    admin only ever sees a payload-free list view (admin_list_payment_
--    events below) -- a payload-revealing RPC is a separate, later,
--    audited piece of work, not added here.
-- ---------------------------------------------------------------------------
CREATE TABLE public.payment_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL CHECK (provider IN ('razorpay', 'payu')),
  event_type text NOT NULL,
  provider_event_id text,
  provider_txn_id text,
  merchant_txn_id text,
  user_id uuid REFERENCES public.users(id) ON DELETE SET NULL,
  subscription_id uuid REFERENCES public.subscriptions(id) ON DELETE SET NULL,
  amount numeric,
  currency text,
  status text,
  signature_verified boolean NOT NULL DEFAULT false,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.payment_events IS
  'Provider-agnostic webhook/callback log (Razorpay and, going forward, PayU) -- the equivalent of razorpay_events, generalized. service_role only: no client policy of any kind, no client grant. Written and read exclusively by an edge function. UNIQUE(provider, provider_event_id) where present makes a replayed webhook a no-op re-insert rather than a double-processed event.';
COMMENT ON COLUMN public.payment_events.provider_txn_id IS
  'The gateway''s own transaction id for this event -- PayU mihpayid, Razorpay payment id.';
COMMENT ON COLUMN public.payment_events.merchant_txn_id IS
  'Our own txnid, generated when the charge/checkout was initiated (PayU requires one; useful to correlate on the Razorpay side too).';

CREATE UNIQUE INDEX idx_payment_events_provider_event_id
  ON public.payment_events (provider, provider_event_id)
  WHERE provider_event_id IS NOT NULL;

CREATE INDEX idx_payment_events_merchant_txn_id ON public.payment_events (merchant_txn_id);
CREATE INDEX idx_payment_events_user_created ON public.payment_events (user_id, created_at);

ALTER TABLE public.payment_events ENABLE ROW LEVEL SECURITY;
-- Deliberately zero policies: RLS default-denies every command for every
-- role that isn't exempt. service_role is exempt (its own role attribute)
-- and holds the explicit grant below; anon/authenticated get nothing.

REVOKE ALL ON public.payment_events FROM anon;
REVOKE ALL ON public.payment_events FROM authenticated;
GRANT ALL ON public.payment_events TO service_role;

-- ---------------------------------------------------------------------------
-- 3. admin_list_payment_events -- list view only, payload deliberately
--    excluded (can carry cardholder-adjacent fragments; not needed to
--    triage a list of events). A payload-revealing RPC, if ever needed,
--    is separate, later, and audited -- not added here.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_payment_events(
  p_provider text DEFAULT NULL,
  p_user_id uuid DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
) RETURNS TABLE (
  id uuid,
  provider text,
  event_type text,
  provider_event_id text,
  provider_txn_id text,
  merchant_txn_id text,
  user_id uuid,
  subscription_id uuid,
  amount numeric,
  currency text,
  status text,
  signature_verified boolean,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  RETURN QUERY
  SELECT
    e.id, e.provider, e.event_type, e.provider_event_id, e.provider_txn_id, e.merchant_txn_id,
    e.user_id, e.subscription_id, e.amount, e.currency, e.status, e.signature_verified, e.created_at
  FROM public.payment_events e
  WHERE (p_provider IS NULL OR e.provider = p_provider)
    AND (p_user_id IS NULL OR e.user_id = p_user_id)
    AND (p_status IS NULL OR e.status = p_status)
  ORDER BY e.created_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.admin_list_payment_events(text, uuid, text, int, int) IS
  'Any active admin. Every payment_events row (optionally filtered by provider/user/status), EXCLUDING payload -- a list-view read only. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_payment_events(text, uuid, text, int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_list_payment_events(text, uuid, text, int, int) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_payment_events(text, uuid, text, int, int) TO authenticated, service_role;
