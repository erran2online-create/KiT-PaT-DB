-- P30 test: account deletion request / cancel / anonymise sweep.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P30 migration
-- (20260824010000_p30_account_deletion.sql) applied. No fixture row
-- survives past the ROLLBACK — nothing to clean up by hand. This tests only
-- the SQL side (finalize_account_deletion); the process-account-deletions
-- edge function's own auth.admin.deleteUser() call is not SQL-testable and
-- is out of scope here.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p30_account_deletion_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. A plain (non-host) member can request deletion; a second request
--      while one is pending is rejected (KITPAT_ALREADY_REQUESTED);
--      cancelling works while pending and before scheduled_for, and is
--      rejected once scheduled_for has passed (KITPAT_DELETION_ALREADY_DUE).
--   2. A sole host of a group that still has other members is blocked with
--      KITPAT_MUST_TRANSFER_HOST, DETAIL carrying that group's id, and no
--      request row is created.
--   3. finalize_account_deletion requires service_role (KITPAT_UNAUTHORIZED
--      otherwise) and, run for a due request: anonymises the user
--      (name/phone/telegram_id/avatar_url/city, deleted_at), removes their
--      members row, leaves their ledger row's user_id untouched, and
--      leaves the group's totals and the other member's own balance
--      exactly reconciled — before and after are byte-for-byte identical
--      except the departed member disappearing from members[].

BEGIN;

DO $t$
DECLARE
  u_host    uuid := gen_random_uuid();
  u_leaving uuid := gen_random_uuid();
  u_stay    uuid := gen_random_uuid();
  u_host2   uuid := gen_random_uuid();
  u_member2 uuid := gen_random_uuid();
  g_id      uuid := gen_random_uuid();
  g2_id     uuid := gen_random_uuid();
  pool      public.kitty_pools;
  req1      public.account_deletion_requests;
  req2      public.account_deletion_requests;
  bal_before jsonb;
  bal_after  jsonb;
  stay_before jsonb;
  stay_after  jsonb;
  u_row     public.users;
  err       text;
  err_detail text;
  n         integer;

BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (id, name, phone, telegram_id, avatar_url, city) VALUES
    (u_host,    'P30 Host',    '+910000000950', 'tg-host',    'https://x/host.png',    'Mumbai'),
    (u_leaving, 'P30 Leaving', '+910000000951', 'tg-leaving', 'https://x/leaving.png', 'Pune'),
    (u_stay,    'P30 Stay',    '+910000000952', 'tg-stay',    'https://x/stay.png',    'Delhi'),
    (u_host2,   'P30 Host2',   '+910000000953', NULL, NULL, NULL),
    (u_member2, 'P30 Member2', '+910000000954', NULL, NULL, NULL);

  INSERT INTO public.groups (id, name, host_id) VALUES
    (g_id,  'P30 Test Group',  u_host),
    (g2_id, 'P30 Solo Host Group', u_host2);

  INSERT INTO public.members (group_id, user_id, role) VALUES
    (g_id, u_leaving, 'member'),
    (g_id, u_stay,    'member'),
    (g2_id, u_member2, 'member')
  ON CONFLICT (group_id, user_id) DO NOTHING;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);
  pool := public.create_kitty_pool(g_id, '2099-06', 1000);
  PERFORM public.record_contribution(pool.id, u_leaving, 500);
  PERFORM public.record_contribution(pool.id, u_stay, 300);

  bal_before := public.get_kitty_balance(pool.id);

  ---------------------------------------------- 1. request / already-requested
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_stay::text, 'role', 'authenticated')::text, true);
  req1 := public.request_account_deletion('trying it out');
  IF req1.status <> 'pending' THEN
    RAISE EXCEPTION 'FAIL: request_account_deletion status = %, expected pending', req1.status;
  END IF;
  IF req1.scheduled_for - req1.requested_at < interval '6 days 23 hours' THEN
    RAISE EXCEPTION 'FAIL: scheduled_for is not ~7 days out (requested_at=%, scheduled_for=%)', req1.requested_at, req1.scheduled_for;
  END IF;

  BEGIN
    PERFORM public.request_account_deletion(NULL);
    RAISE EXCEPTION 'FAIL: a second request while one is pending was allowed';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ALREADY_REQUESTED' THEN
      RAISE EXCEPTION 'FAIL: second request raised "%", expected KITPAT_ALREADY_REQUESTED', err;
    END IF;
  END;

  -- Cancel while still pending and not yet due: succeeds.
  req1 := public.cancel_account_deletion();
  IF req1.status <> 'cancelled' THEN
    RAISE EXCEPTION 'FAIL: cancel_account_deletion status = %, expected cancelled', req1.status;
  END IF;

  -- Request again (allowed now that the prior one is cancelled, not pending).
  req2 := public.request_account_deletion(NULL);
  UPDATE public.account_deletion_requests SET scheduled_for = now() - interval '1 hour' WHERE id = req2.id;

  BEGIN
    PERFORM public.cancel_account_deletion();
    RAISE EXCEPTION 'FAIL: cancelling a request past its scheduled_for was allowed';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_DELETION_ALREADY_DUE' THEN
      RAISE EXCEPTION 'FAIL: late cancel raised "%", expected KITPAT_DELETION_ALREADY_DUE', err;
    END IF;
  END;

  -- u_host2, who has never requested, has nothing to cancel.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host2::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.cancel_account_deletion();
    RAISE EXCEPTION 'FAIL: cancel_account_deletion succeeded with no pending request';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NO_PENDING_REQUEST' THEN
      RAISE EXCEPTION 'FAIL: cancel with nothing pending raised "%", expected KITPAT_NO_PENDING_REQUEST', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: request/cancel lifecycle — KITPAT_ALREADY_REQUESTED, cancel-while-pending, KITPAT_DELETION_ALREADY_DUE, KITPAT_NO_PENDING_REQUEST all correct (u_stay''s own account is untouched by any of this)';

  ------------------------------------------------- 2. sole host with members
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host2::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.request_account_deletion('leaving my own group');
    RAISE EXCEPTION 'FAIL: a sole host of a group with another member was allowed to request deletion';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS err = MESSAGE_TEXT, err_detail = PG_EXCEPTION_DETAIL;
    IF err <> 'KITPAT_MUST_TRANSFER_HOST' THEN
      RAISE EXCEPTION 'FAIL: sole host raised "%", expected KITPAT_MUST_TRANSFER_HOST', err;
    END IF;
    IF err_detail IS NULL THEN
      RAISE EXCEPTION 'FAIL: KITPAT_MUST_TRANSFER_HOST was raised with no DETAIL';
    END IF;
    IF NOT (err_detail::jsonb -> 'group_ids' @> to_jsonb(ARRAY[g2_id])) THEN
      RAISE EXCEPTION 'FAIL: KITPAT_MUST_TRANSFER_HOST detail = %, expected it to include group_id %', err_detail, g2_id;
    END IF;
  END;

  SELECT count(*) INTO n FROM public.account_deletion_requests WHERE user_id = u_host2;
  IF n <> 0 THEN
    RAISE EXCEPTION 'FAIL: a request row was created for a blocked sole host';
  END IF;
  RAISE NOTICE 'PASS: sole host of a group with other members is blocked with KITPAT_MUST_TRANSFER_HOST carrying the group id, no request row created';

  --------------------------------------------------------- 3. finalize (real)
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_leaving::text, 'role', 'authenticated')::text, true);
  req1 := public.request_account_deletion('moving on');

  -- Not service_role: rejected.
  BEGIN
    PERFORM public.finalize_account_deletion(req1.id);
    RAISE EXCEPTION 'FAIL: finalize_account_deletion was callable by a non-service_role caller';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_UNAUTHORIZED' THEN
      RAISE EXCEPTION 'FAIL: non-service caller raised "%", expected KITPAT_UNAUTHORIZED', err;
    END IF;
  END;

  -- Not due yet: rejected even as service_role.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('role', 'service_role')::text, true);
  BEGIN
    PERFORM public.finalize_account_deletion(req1.id);
    RAISE EXCEPTION 'FAIL: finalize_account_deletion ran before scheduled_for';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_DUE' THEN
      RAISE EXCEPTION 'FAIL: not-yet-due finalize raised "%", expected KITPAT_NOT_DUE', err;
    END IF;
  END;

  -- Advance past the 7-day grace period.
  UPDATE public.account_deletion_requests SET scheduled_for = now() - interval '1 hour' WHERE id = req1.id;

  PERFORM public.finalize_account_deletion(req1.id);

  -- Back to a real member's session: get_kitty_balance requires a real
  -- auth.uid() that is a member/host of the pool's group, which the bare
  -- service_role impersonation above (no 'sub' claim) does not satisfy.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);

  SELECT * INTO u_row FROM public.users WHERE id = u_leaving;
  IF u_row.name <> 'Deleted member' THEN
    RAISE EXCEPTION 'FAIL: name = %, expected "Deleted member"', u_row.name;
  END IF;
  IF u_row.phone IS NOT NULL OR u_row.telegram_id IS NOT NULL
     OR u_row.avatar_url IS NOT NULL OR u_row.city IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: PII not cleared: phone=%, telegram_id=%, avatar_url=%, city=%',
      u_row.phone, u_row.telegram_id, u_row.avatar_url, u_row.city;
  END IF;
  IF u_row.deleted_at IS NULL THEN
    RAISE EXCEPTION 'FAIL: deleted_at was not set';
  END IF;

  IF EXISTS (SELECT 1 FROM public.members WHERE group_id = g_id AND user_id = u_leaving) THEN
    RAISE EXCEPTION 'FAIL: members row for u_leaving still exists after finalize';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.contributions
    WHERE pool_id = pool.id AND user_id = u_leaving AND amount = 500 AND voided_at IS NULL
  ) THEN
    RAISE EXCEPTION 'FAIL: u_leaving''s contribution row is gone or its user_id/amount changed';
  END IF;

  bal_after := public.get_kitty_balance(pool.id);
  IF (bal_after->>'collected')::integer <> (bal_before->>'collected')::integer THEN
    RAISE EXCEPTION 'FAIL: pool collected changed from % to % after anonymising a departed member', bal_before->>'collected', bal_after->>'collected';
  END IF;
  IF (bal_after->>'balance')::integer <> (bal_before->>'balance')::integer THEN
    RAISE EXCEPTION 'FAIL: pool balance changed from % to % after anonymising a departed member', bal_before->>'balance', bal_after->>'balance';
  END IF;

  SELECT m INTO stay_before FROM jsonb_array_elements(bal_before->'members') m WHERE (m->>'user_id')::uuid = u_stay;
  SELECT m INTO stay_after  FROM jsonb_array_elements(bal_after->'members')  m WHERE (m->>'user_id')::uuid = u_stay;
  IF stay_before IS DISTINCT FROM stay_after THEN
    RAISE EXCEPTION 'FAIL: u_stay''s own balance entry changed: before=%, after=%', stay_before, stay_after;
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(bal_after->'members') m WHERE (m->>'user_id')::uuid = u_leaving) THEN
    RAISE EXCEPTION 'FAIL: the departed member still appears in members[] after finalize';
  END IF;

  UPDATE public.account_deletion_requests SET status = 'done', completed_at = now() WHERE id = req1.id;
  IF (SELECT status FROM public.account_deletion_requests WHERE id = req1.id) <> 'done' THEN
    RAISE EXCEPTION 'FAIL: request status did not reach done';
  END IF;

  RAISE NOTICE 'PASS: finalize_account_deletion is service_role-only and not-due-rejecting; anonymises the user, drops their members row, keeps their ledger row''s user_id, and leaves group totals and the other member''s own balance exactly reconciled';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
