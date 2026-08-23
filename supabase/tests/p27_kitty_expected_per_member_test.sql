-- P27 test: kitty_pools.expected_per_member + get_kitty_balance frozen contract.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P27 migration
-- (20260823120000_p27_kitty_expected_per_member.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p27_kitty_expected_per_member_test.sql
--
-- Any failed assertion aborts with a "P27 FAIL: ..." exception. Success prints
-- "P27 PASS" notices and rolls back.
--
-- Proves:
--   1. create_kitty_pool(..., 2000) sets expected_per_member = 2000, and
--      re-running it without the argument preserves that value.
--   2. create_kitty_pool rejects a non-positive target with
--      KITPAT_INVALID_AMOUNT.
--   3. With expected_per_member = 2000 and three members paying 2000 / 500 / 0,
--      get_kitty_balance reports status paid/partial/pending and
--      amount_pending 0/1500/2000 respectively, joined to public.users so
--      every member row carries a name and never a bare UUID.
--   4. A non-member of the group gets KITPAT_NOT_MEMBER from get_kitty_balance.
--   5. set_pool_expected is host-only (KITPAT_NOT_HOST for a plain member)
--      and changing the target changes amount_pending/status on the next
--      read without touching amount_paid or collected.
--   6. Every money key in the response (collected, spent, balance) is a
--      number, never null, even for a pool with zero activity.

BEGIN;

DO $p27$
DECLARE
  u_host      uuid := gen_random_uuid();
  u_paid_full uuid := gen_random_uuid();
  u_partial   uuid := gen_random_uuid();
  u_unpaid    uuid := gen_random_uuid();
  u_outsider  uuid := gen_random_uuid();
  g_id        uuid := gen_random_uuid();
  g_other     uuid := gen_random_uuid();
  pool        public.kitty_pools;
  bal         jsonb;
  member_row  jsonb;
  err         text;

BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (id, name, phone) VALUES
    (u_host,      'P27 Host',        '+910000000929'),
    (u_paid_full, 'P27 Paid Full',   '+910000000930'),
    (u_partial,   'P27 Paid Partial','+910000000931'),
    (u_unpaid,    'P27 Unpaid',      '+910000000932'),
    (u_outsider,  'P27 Outsider',    '+910000000933');

  INSERT INTO public.groups (id, name, host_id) VALUES
    (g_id,    'P27 Test Group',   u_host),
    (g_other, 'P27 Other Group',  u_outsider);

  -- A trigger on public.groups already enrols the host as a member.
  INSERT INTO public.members (group_id, user_id, role) VALUES
    (g_id, u_host,      'host'),
    (g_id, u_paid_full, 'member'),
    (g_id, u_partial,   'member'),
    (g_id, u_unpaid,    'member')
  ON CONFLICT (group_id, user_id) DO NOTHING;

  -- Act as the host.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text,
    true
  );

  --------------------------------------- 1. create_kitty_pool sets the target
  pool := public.create_kitty_pool(g_id, '2099-03', 2000);
  IF pool.expected_per_member IS DISTINCT FROM 2000 THEN
    RAISE EXCEPTION 'P27 FAIL: expected_per_member = %, expected 2000', pool.expected_per_member;
  END IF;

  -- Re-running create for the same month without an amount must not clear it.
  pool := public.create_kitty_pool(g_id, '2099-03');
  IF pool.expected_per_member IS DISTINCT FROM 2000 THEN
    RAISE EXCEPTION 'P27 FAIL: re-running create_kitty_pool without an amount cleared expected_per_member (now %)', pool.expected_per_member;
  END IF;
  RAISE NOTICE 'P27 PASS: create_kitty_pool sets and preserves expected_per_member';

  ------------------------------------------- 2. non-positive target rejected
  BEGIN
    PERFORM public.create_kitty_pool(g_id, '2099-04', 0);
    RAISE EXCEPTION 'P27 FAIL: create_kitty_pool accepted a zero expected_per_member';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INVALID_AMOUNT' THEN
      RAISE EXCEPTION 'P27 FAIL: zero amount raised "%", expected KITPAT_INVALID_AMOUNT', err;
    END IF;
  END;
  RAISE NOTICE 'P27 PASS: create_kitty_pool rejects a non-positive expected_per_member';

  ------------------------------------------ 3. record the three contributions
  PERFORM public.record_contribution(pool.id, u_paid_full, 2000);
  PERFORM public.record_contribution(pool.id, u_partial, 500);
  -- u_unpaid pays nothing.

  bal := public.get_kitty_balance(pool.id);

  IF (bal->>'ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'P27 FAIL: get_kitty_balance did not return ok=true';
  END IF;
  IF (bal->>'expected_per_member')::integer <> 2000 THEN
    RAISE EXCEPTION 'P27 FAIL: balance expected_per_member = %, expected 2000', bal->>'expected_per_member';
  END IF;
  IF (bal->>'collected')::integer <> 2500 THEN
    RAISE EXCEPTION 'P27 FAIL: collected = %, expected 2500', bal->>'collected';
  END IF;
  IF bal->>'collected' IS NULL OR bal->>'spent' IS NULL OR bal->>'balance' IS NULL THEN
    RAISE EXCEPTION 'P27 FAIL: a money key was null: %', bal::text;
  END IF;

  -- u_paid_full: paid in full -> pending 0, status paid.
  SELECT m INTO member_row FROM jsonb_array_elements(bal->'members') m
    WHERE (m->>'user_id')::uuid = u_paid_full;
  IF member_row IS NULL THEN
    RAISE EXCEPTION 'P27 FAIL: u_paid_full missing from members[]';
  END IF;
  IF member_row->>'name' IS NULL OR member_row->>'name' <> 'P27 Paid Full' THEN
    RAISE EXCEPTION 'P27 FAIL: u_paid_full name = %, expected joined "P27 Paid Full"', member_row->>'name';
  END IF;
  IF (member_row->>'amount_paid')::integer <> 2000 THEN
    RAISE EXCEPTION 'P27 FAIL: u_paid_full amount_paid = %, expected 2000', member_row->>'amount_paid';
  END IF;
  IF (member_row->>'amount_pending')::integer <> 0 THEN
    RAISE EXCEPTION 'P27 FAIL: u_paid_full amount_pending = %, expected 0', member_row->>'amount_pending';
  END IF;
  IF member_row->>'status' <> 'paid' THEN
    RAISE EXCEPTION 'P27 FAIL: u_paid_full status = %, expected paid', member_row->>'status';
  END IF;

  -- u_partial: paid 500 of 2000 -> pending 1500, status partial.
  SELECT m INTO member_row FROM jsonb_array_elements(bal->'members') m
    WHERE (m->>'user_id')::uuid = u_partial;
  IF (member_row->>'amount_paid')::integer <> 500 THEN
    RAISE EXCEPTION 'P27 FAIL: u_partial amount_paid = %, expected 500', member_row->>'amount_paid';
  END IF;
  IF (member_row->>'amount_pending')::integer <> 1500 THEN
    RAISE EXCEPTION 'P27 FAIL: u_partial amount_pending = %, expected 1500', member_row->>'amount_pending';
  END IF;
  IF member_row->>'status' <> 'partial' THEN
    RAISE EXCEPTION 'P27 FAIL: u_partial status = %, expected partial', member_row->>'status';
  END IF;

  -- u_unpaid: paid 0 of 2000 -> pending 2000, status pending.
  SELECT m INTO member_row FROM jsonb_array_elements(bal->'members') m
    WHERE (m->>'user_id')::uuid = u_unpaid;
  IF (member_row->>'amount_paid')::integer <> 0 THEN
    RAISE EXCEPTION 'P27 FAIL: u_unpaid amount_paid = %, expected 0', member_row->>'amount_paid';
  END IF;
  IF (member_row->>'amount_pending')::integer <> 2000 THEN
    RAISE EXCEPTION 'P27 FAIL: u_unpaid amount_pending = %, expected 2000', member_row->>'amount_pending';
  END IF;
  IF member_row->>'status' <> 'pending' THEN
    RAISE EXCEPTION 'P27 FAIL: u_unpaid status = %, expected pending', member_row->>'status';
  END IF;
  RAISE NOTICE 'P27 PASS: statuses paid/partial/pending and amount_pending 0/1500/2000 for 2000/500/0 paid against a 2000 target';

  --------------------------------------------- 4. non-member is rejected
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', u_outsider::text, 'role', 'authenticated')::text,
    true
  );
  BEGIN
    bal := public.get_kitty_balance(pool.id);
    RAISE EXCEPTION 'P27 FAIL: a non-member was allowed to read get_kitty_balance';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_MEMBER' THEN
      RAISE EXCEPTION 'P27 FAIL: non-member raised "%", expected KITPAT_NOT_MEMBER', err;
    END IF;
  END;
  RAISE NOTICE 'P27 PASS: KITPAT_NOT_MEMBER raised for a non-member';

  ------------------------------------------- 5. set_pool_expected host-only
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', u_partial::text, 'role', 'authenticated')::text,
    true
  );
  BEGIN
    PERFORM public.set_pool_expected(pool.id, 1000);
    RAISE EXCEPTION 'P27 FAIL: a non-host group member was allowed to set_pool_expected';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_HOST' THEN
      RAISE EXCEPTION 'P27 FAIL: non-host set_pool_expected raised "%", expected KITPAT_NOT_HOST', err;
    END IF;
  END;

  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text,
    true
  );
  pool := public.set_pool_expected(pool.id, 1000);
  IF pool.expected_per_member IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'P27 FAIL: set_pool_expected did not update expected_per_member (now %)', pool.expected_per_member;
  END IF;

  bal := public.get_kitty_balance(pool.id);
  IF (bal->>'collected')::integer <> 2500 THEN
    RAISE EXCEPTION 'P27 FAIL: collected changed after set_pool_expected (now %), expected unchanged 2500', bal->>'collected';
  END IF;
  SELECT m INTO member_row FROM jsonb_array_elements(bal->'members') m
    WHERE (m->>'user_id')::uuid = u_partial;
  IF (member_row->>'amount_pending')::integer <> 500 THEN
    RAISE EXCEPTION 'P27 FAIL: after lowering target to 1000, u_partial amount_pending = %, expected 500', member_row->>'amount_pending';
  END IF;
  IF member_row->>'status' <> 'partial' THEN
    RAISE EXCEPTION 'P27 FAIL: u_partial status after retarget = %, expected still partial', member_row->>'status';
  END IF;
  RAISE NOTICE 'P27 PASS: set_pool_expected is host-only and a retarget updates amount_pending/status without touching collected';

  ------------------------------------------- 6. zero-activity pool: no nulls
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text,
    true
  );
  pool := public.create_kitty_pool(g_id, '2099-05');
  bal := public.get_kitty_balance(pool.id);
  IF (bal->>'collected')::integer <> 0 OR (bal->>'spent')::integer <> 0 OR (bal->>'balance')::integer <> 0 THEN
    RAISE EXCEPTION 'P27 FAIL: fresh pool money keys = %, expected all 0', bal::text;
  END IF;
  IF bal->'expected_per_member' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'P27 FAIL: fresh pool expected_per_member = %, expected null', bal->'expected_per_member';
  END IF;
  RAISE NOTICE 'P27 PASS: a zero-activity pool returns 0 money keys, never null';

  RAISE NOTICE 'P27 ALL ASSERTIONS PASSED';
END;
$p27$;

ROLLBACK;
