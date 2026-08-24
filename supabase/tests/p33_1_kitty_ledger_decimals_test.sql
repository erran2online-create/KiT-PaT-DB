-- P33.1 test: kitty ledger amounts survive decimals end to end.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P33.1 migration
-- (20260824030000_p33_1_kitty_ledger_decimals.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p33_1_kitty_ledger_decimals_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. record_contribution(1250.50) reads back as exactly 1250.50 (not
--      1250, not 1251, not 1250.5 that compares unequal) in
--      get_kitty_balance's collected/balance and the member's amount_paid.
--   2. record_expense(375.25) similarly survives into spent/balance.
--   3. void_contribution() on the 1250.50 row re-settles collected to
--      exactly 0.00 (not just "falsy zero" — the actual numeric value).
--   4. The P26/P27 contract keys (ok, expected_per_member,
--      totals_consistent, voided_contributions, members[].status) are all
--      still present and correctly computed against decimal amounts.

BEGIN;

DO $t$
DECLARE
  u_host uuid := gen_random_uuid();
  u_member uuid := gen_random_uuid();
  g_id uuid := gen_random_uuid();
  pool public.kitty_pools;
  contrib public.contributions;
  exp public.kitty_expenses;
  bal jsonb;
  member_row jsonb;

BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (id, name, phone) VALUES
    (u_host,   'P33.1 Host',   '+910000000970'),
    (u_member, 'P33.1 Member', '+910000000971');

  INSERT INTO public.groups (id, name, host_id) VALUES
    (g_id, 'P33.1 Test Group', u_host);

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);
  pool := public.create_kitty_pool(g_id, '2099-07', 2000);

  ------------------------------------------------ 1. contribution round-trip
  contrib := public.record_contribution(pool.id, u_member, 1250.50);
  IF contrib.amount <> 1250.50 THEN
    RAISE EXCEPTION 'FAIL: contributions.amount = %, expected exactly 1250.50', contrib.amount;
  END IF;

  bal := public.get_kitty_balance(pool.id);
  IF (bal->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: get_kitty_balance did not return ok=true';
  END IF;
  IF (bal->>'collected')::numeric <> 1250.50 THEN
    RAISE EXCEPTION 'FAIL: collected = %, expected exactly 1250.50', bal->>'collected';
  END IF;
  IF (bal->>'balance')::numeric <> 1250.50 THEN
    RAISE EXCEPTION 'FAIL: balance = %, expected exactly 1250.50', bal->>'balance';
  END IF;
  IF (bal->>'expected_per_member')::numeric <> 2000 THEN
    RAISE EXCEPTION 'FAIL: expected_per_member = %, expected 2000 (untouched by this migration)', bal->>'expected_per_member';
  END IF;

  SELECT m INTO member_row FROM jsonb_array_elements(bal->'members') m WHERE (m->>'user_id')::uuid = u_member;
  IF (member_row->>'amount_paid')::numeric <> 1250.50 THEN
    RAISE EXCEPTION 'FAIL: member amount_paid = %, expected exactly 1250.50', member_row->>'amount_paid';
  END IF;
  IF (member_row->>'amount_pending')::numeric <> 749.50 THEN
    RAISE EXCEPTION 'FAIL: member amount_pending = %, expected exactly 749.50 (2000 - 1250.50)', member_row->>'amount_pending';
  END IF;
  IF member_row->>'status' <> 'partial' THEN
    RAISE EXCEPTION 'FAIL: member status = %, expected partial', member_row->>'status';
  END IF;
  RAISE NOTICE 'PASS: 1250.50 contribution round-trips exactly through get_kitty_balance (collected/balance/amount_paid/amount_pending/status)';

  --------------------------------------------------------- 2. expense round-trip
  exp := public.record_expense(pool.id, 375.25, 'P33.1 Vendor', 'food');
  IF exp.amount <> 375.25 THEN
    RAISE EXCEPTION 'FAIL: kitty_expenses.amount = %, expected exactly 375.25', exp.amount;
  END IF;

  bal := public.get_kitty_balance(pool.id);
  IF (bal->>'spent')::numeric <> 375.25 THEN
    RAISE EXCEPTION 'FAIL: spent = %, expected exactly 375.25', bal->>'spent';
  END IF;
  IF (bal->>'balance')::numeric <> 875.25 THEN
    RAISE EXCEPTION 'FAIL: balance = %, expected exactly 1250.50 - 375.25 = 875.25', bal->>'balance';
  END IF;
  IF NOT (bal->>'totals_consistent')::boolean THEN
    RAISE EXCEPTION 'FAIL: totals_consistent = false with no voids yet';
  END IF;
  RAISE NOTICE 'PASS: 375.25 expense round-trips exactly (spent/balance)';

  ------------------------------------------------- 3. void re-settles to 0.00
  PERFORM public.void_contribution(contrib.id, 'test void');

  bal := public.get_kitty_balance(pool.id);
  IF (bal->>'collected')::numeric <> 0.00 THEN
    RAISE EXCEPTION 'FAIL: collected after voiding the only contribution = %, expected exactly 0.00', bal->>'collected';
  END IF;
  IF (bal->>'balance')::numeric <> -375.25 THEN
    RAISE EXCEPTION 'FAIL: balance after void = %, expected exactly 0.00 - 375.25 = -375.25', bal->>'balance';
  END IF;
  IF (bal->>'voided_contributions')::integer <> 1 THEN
    RAISE EXCEPTION 'FAIL: voided_contributions = %, expected 1', bal->>'voided_contributions';
  END IF;
  IF NOT (bal->>'totals_consistent')::boolean THEN
    RAISE EXCEPTION 'FAIL: totals_consistent = false after a clean void';
  END IF;

  SELECT m INTO member_row FROM jsonb_array_elements(bal->'members') m WHERE (m->>'user_id')::uuid = u_member;
  IF member_row->>'status' <> 'pending' THEN
    RAISE EXCEPTION 'FAIL: member status after their only contribution was voided = %, expected pending', member_row->>'status';
  END IF;
  IF (member_row->>'amount_pending')::numeric <> 2000.00 THEN
    RAISE EXCEPTION 'FAIL: member amount_pending after void = %, expected exactly 2000.00', member_row->>'amount_pending';
  END IF;

  -- Confirm the underlying accumulator itself is exactly 0.00, not just
  -- falsy-zero via coalesce.
  IF (SELECT total_collected FROM public.kitty_pools WHERE id = pool.id) <> 0.00 THEN
    RAISE EXCEPTION 'FAIL: kitty_pools.total_collected after void = %, expected exactly 0.00', (SELECT total_collected FROM public.kitty_pools WHERE id = pool.id);
  END IF;
  RAISE NOTICE 'PASS: voiding the 1250.50 contribution re-settles total_collected/collected to exactly 0.00, balance and member status update accordingly';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
