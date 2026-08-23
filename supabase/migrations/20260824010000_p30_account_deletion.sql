-- P30: account deletion — request, cancel, and a daily anonymise sweep.
--
-- Confirmed live state before writing this (not re-queried; no DB access):
--   no account_deletion_requests table and no deletion RPCs exist yet.
--   public.users already has deleted_at, name, phone, telegram_id,
--   avatar_url, city. public.members has group_id, user_id, role.
--   public.is_group_host(group_id, user_id) already exists.
--   contributions.user_id and kitty_expenses.added_by are
--   `NOT NULL REFERENCES public.users(id)` with NO ON DELETE clause (plain
--   RESTRICT) — a hard DELETE of a public.users row referenced by any ledger
--   row would fail outright. There is also no FK from public.users.id to
--   auth.users.id in this schema, so deleting the auth.users row does not
--   cascade back onto public.users. Both facts are exactly why this design
--   anonymises the public.users row in place rather than deleting it: the
--   row keeps existing (satisfying every ledger FK, so group totals and
--   other members' balances never move), and deleting auth.users afterward
--   touches nothing else.
--
-- Account deletion was previously a stub in the app and entirely absent
-- from the backend; both app stores reject a listing without a working
-- deletion path.
--
-- This migration adds:
--   1. account_deletion_requests (id, user_id, requested_at, scheduled_for,
--      status, reason) — one row per request, 7-day grace period.
--   2. request_account_deletion(p_reason) — caller-only. Blocks with
--      KITPAT_MUST_TRANSFER_HOST (group ids in the exception DETAIL) if the
--      caller is host of a group that still has other members: a group's
--      ledger history must never lose its host to a member who just leaves.
--      Stable codes: KITPAT_UNAUTHENTICATED / KITPAT_ALREADY_REQUESTED /
--      KITPAT_MUST_TRANSFER_HOST.
--   3. cancel_account_deletion() — self-only, only while the request is
--      still 'pending' and scheduled_for hasn't passed.
--   4. finalize_account_deletion(p_request_id) — service_role only. Called
--      by the process-account-deletions edge function once per due request:
--      anonymises public.users (name/phone/telegram_id/avatar_url/city,
--      sets deleted_at) and deletes the caller's public.members rows.
--      Ledger rows are untouched (their user_id FK now points at an
--      anonymised-but-present row). Does NOT delete auth.users or mark the
--      request done — those happen from the edge function, in that order,
--      since an auth.users delete is a GoTrue Admin API call that cannot
--      participate in this same Postgres transaction. Re-running this
--      function against an already-anonymised user/removed members is a
--      safe no-op, so a crashed/retried edge function run cannot double
--      apply anything or get stuck.
--   5. trigger_process_account_deletions() + a daily pg_cron schedule that
--      POSTs to the process-account-deletions edge function, mirroring the
--      existing tambola_broadcast() vault-secret HTTP pattern.
--
-- Additive only: one new table, four new functions, one new pg_cron
-- schedule. No existing table, column, or row is altered by this file.

-- ---------------------------------------------------------------------------
-- 1. account_deletion_requests
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.account_deletion_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.users(id),
  requested_at timestamptz NOT NULL DEFAULT now(),
  scheduled_for timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  reason text,
  cancelled_at timestamptz,
  completed_at timestamptz,
  CONSTRAINT account_deletion_requests_status_check CHECK (
    status = ANY (ARRAY['pending'::text, 'cancelled'::text, 'done'::text])
  )
);

-- Defensive backstop behind the explicit KITPAT_ALREADY_REQUESTED check in
-- request_account_deletion(): at most one pending request per user.
CREATE UNIQUE INDEX IF NOT EXISTS idx_account_deletion_requests_one_pending_per_user
  ON public.account_deletion_requests (user_id)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_account_deletion_requests_due
  ON public.account_deletion_requests (scheduled_for)
  WHERE status = 'pending';

COMMENT ON TABLE public.account_deletion_requests IS
  'One row per account-deletion request. 7-day grace period (scheduled_for). process-account-deletions (edge function, daily pg_cron) anonymises + closes out any row still pending past scheduled_for.';

ALTER TABLE public.account_deletion_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS account_deletion_requests_read_own ON public.account_deletion_requests;
CREATE POLICY account_deletion_requests_read_own ON public.account_deletion_requests
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));

REVOKE ALL ON TABLE public.account_deletion_requests FROM anon;
GRANT SELECT ON TABLE public.account_deletion_requests TO authenticated;
GRANT ALL ON TABLE public.account_deletion_requests TO service_role;

-- ---------------------------------------------------------------------------
-- 2. request_account_deletion — caller only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_account_deletion(
  p_reason text DEFAULT NULL
) RETURNS public.account_deletion_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  req public.account_deletion_requests;
  sole_host_groups uuid[];
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests
    WHERE user_id = uid AND status = 'pending'
  ) THEN
    RAISE EXCEPTION 'KITPAT_ALREADY_REQUESTED' USING ERRCODE = 'PT409';
  END IF;

  -- Groups where the caller is host AND at least one other member remains:
  -- a group's ledger history must never die because its host leaves. groups
  -- has exactly one host_id, so "is host" here already means "sole host".
  SELECT coalesce(array_agg(g.id), '{}')
    INTO sole_host_groups
  FROM public.groups g
  WHERE public.is_group_host(g.id, uid)
    AND EXISTS (
      SELECT 1 FROM public.members m
      WHERE m.group_id = g.id AND m.user_id <> uid
    );

  IF array_length(sole_host_groups, 1) > 0 THEN
    RAISE EXCEPTION 'KITPAT_MUST_TRANSFER_HOST'
      USING ERRCODE = 'PT409',
            DETAIL = jsonb_build_object('group_ids', to_jsonb(sole_host_groups))::text;
  END IF;

  INSERT INTO public.account_deletion_requests (user_id, scheduled_for, reason)
  VALUES (uid, now() + interval '7 days', nullif(btrim(coalesce(p_reason, '')), ''))
  RETURNING * INTO req;

  RETURN req;
END;
$$;

COMMENT ON FUNCTION public.request_account_deletion(text) IS
  'Caller-only. Creates a pending deletion request with a 7-day grace period. Errors: KITPAT_UNAUTHENTICATED / KITPAT_ALREADY_REQUESTED / KITPAT_MUST_TRANSFER_HOST (DETAIL carries {"group_ids": [...]} for any group the caller must transfer host on first).';

-- ---------------------------------------------------------------------------
-- 3. cancel_account_deletion — self only, pending + not yet due
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_account_deletion() RETURNS public.account_deletion_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  req public.account_deletion_requests;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;

  SELECT * INTO req
  FROM public.account_deletion_requests
  WHERE user_id = uid AND status = 'pending'
  ORDER BY requested_at DESC
  LIMIT 1
  FOR UPDATE;

  IF req.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NO_PENDING_REQUEST' USING ERRCODE = 'PT404';
  END IF;
  IF req.scheduled_for <= now() THEN
    RAISE EXCEPTION 'KITPAT_DELETION_ALREADY_DUE' USING ERRCODE = 'PT409';
  END IF;

  UPDATE public.account_deletion_requests
  SET status = 'cancelled',
      cancelled_at = now()
  WHERE id = req.id
  RETURNING * INTO req;

  RETURN req;
END;
$$;

COMMENT ON FUNCTION public.cancel_account_deletion() IS
  'Self-only. Cancels the caller''s own pending deletion request, only before scheduled_for. Errors: KITPAT_UNAUTHENTICATED / KITPAT_NO_PENDING_REQUEST / KITPAT_DELETION_ALREADY_DUE.';

-- ---------------------------------------------------------------------------
-- 4. finalize_account_deletion — service_role only, called from the edge fn
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.finalize_account_deletion(
  p_request_id uuid
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  req public.account_deletion_requests;
BEGIN
  IF coalesce(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHORIZED' USING ERRCODE = 'PT403';
  END IF;

  SELECT * INTO req
  FROM public.account_deletion_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF req.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
  IF req.status <> 'pending' THEN
    RAISE EXCEPTION 'KITPAT_NOT_PENDING' USING ERRCODE = 'PT409';
  END IF;
  IF req.scheduled_for > now() THEN
    RAISE EXCEPTION 'KITPAT_NOT_DUE' USING ERRCODE = 'PT409';
  END IF;

  -- Anonymise, never delete: contributions.user_id / kitty_expenses.added_by
  -- reference this row with no ON DELETE clause, so it must keep existing
  -- for every ledger total and every other member's balance to stay exact.
  UPDATE public.users
  SET name = 'Deleted member',
      phone = NULL,
      telegram_id = NULL,
      avatar_url = NULL,
      city = NULL,
      deleted_at = now()
  WHERE id = req.user_id;

  DELETE FROM public.members WHERE user_id = req.user_id;

  RETURN req.user_id;
END;
$$;

COMMENT ON FUNCTION public.finalize_account_deletion(uuid) IS
  'service_role only. Anonymises the user row and removes their members rows for one due request. Does not touch auth.users or the request status — the calling edge function does both, in that order, since deleting auth.users is a GoTrue Admin API call outside this transaction. Safe to re-run. Errors: KITPAT_UNAUTHORIZED / KITPAT_NOT_FOUND / KITPAT_NOT_PENDING / KITPAT_NOT_DUE.';

REVOKE ALL ON FUNCTION public.request_account_deletion(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_account_deletion() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finalize_account_deletion(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.request_account_deletion(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_account_deletion() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finalize_account_deletion(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Daily pg_cron -> process-account-deletions edge function
-- ---------------------------------------------------------------------------
-- Same vault-secret HTTP pattern as public.tambola_broadcast(): the service
-- role key lives in vault as 'supabase_service_role_key' and is attached as
-- the Authorization bearer token, which the edge function checks verbatim.
CREATE OR REPLACE FUNCTION public.trigger_process_account_deletions() RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp', 'net', 'vault'
AS $$
DECLARE
  svc text;
  project_url text := 'https://hygfknxbytfyagjfdiwo.supabase.co/functions/v1/process-account-deletions';
  req_id bigint;
BEGIN
  SELECT ds.decrypted_secret INTO svc
  FROM vault.decrypted_secrets ds
  WHERE ds.name = 'supabase_service_role_key'
  LIMIT 1;

  IF svc IS NULL OR length(svc) < 20 THEN
    RAISE WARNING 'trigger_process_account_deletions: vault secret supabase_service_role_key not configured';
    RETURN;
  END IF;

  SELECT net.http_post(
    url := project_url,
    body := '{}'::jsonb,
    params := '{}'::jsonb,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', svc,
      'Authorization', 'Bearer ' || svc
    ),
    timeout_milliseconds := 30000
  ) INTO req_id;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'trigger_process_account_deletions HTTP call failed: %', sqlerrm;
END;
$$;

REVOKE ALL ON FUNCTION public.trigger_process_account_deletions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trigger_process_account_deletions() TO service_role;

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

DO $$
DECLARE existing bigint;
BEGIN
  SELECT j.jobid INTO existing FROM cron.job j WHERE j.jobname = 'process-account-deletions-daily' LIMIT 1;
  IF existing IS NOT NULL THEN
    PERFORM cron.unschedule(existing);
  END IF;

  PERFORM cron.schedule(
    'process-account-deletions-daily',
    '0 3 * * *',
    $cron$SELECT public.trigger_process_account_deletions();$cron$
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Could not schedule process-account-deletions-daily cron job: %', sqlerrm;
END;
$$;
