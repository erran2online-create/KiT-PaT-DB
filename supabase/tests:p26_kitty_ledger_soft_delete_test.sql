-- P26 test: kitty ledger soft delete.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P26 migration
-- (20260822130000_p26_kitty_ledger_soft_delete.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p26_kitty_ledger_soft_delete_test.sql
--
-- Any failed assertion aborts with a "P26 FAIL: ..." exception. Success prints
-- "P26 PASS" notices and rolls back.
--
-- Proves:
--   1. record 500 -> read balance -> void -> read again: total_collected fell
--      by exactly 500, the row is still there with voided_at/voided_by set.
--   2. the same for kitty_expenses / total_spent.
--   3. a non-host is rejected with KITPAT_NOT_HOST.
--   4. re-voiding raises KITPAT_ALREADY_VOIDED, unknown id raises
--      KITPAT_NOT_FOUND.
--   5. kitty_pools.total_collected / total_spent cannot drift from
--      sum(non-voided rows) across an interleaved record/void sequence.
--   6. a direct table DELETE as `authenticated` now fails (42501) instead of
--      silently affecting zero rows.

BEGIN;

DO $p26$
DECLARE
  u_host      uuid := gen_random_uuid();
  u_member    uuid := gen_random_uuid();
  u_outsider  uuid := gen_random_uuid();
  g_id        uuid := gen_random_uuid();
  g_other     uuid := gen_random_uuid();
  v_pool      uuid;
  c1          public.contributions;
  c_a         public.contributions;
  c_b         public.contributions;
  c_c         public.contributions;
  e1          public.kitty_expenses;
  e_a         public.kitty_expenses;
  e_b         public.kitty_expenses;
  voided      public.contributions;
  voided_exp  public.kitty_expenses;
  bal         jsonb;
  collected   integer;
  spent       integer;
  live_sum    integer;
  row_count   integer;
  err         text;
  delete_blocked boolean := false;

BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (id, name, phone) VALUES
    (u_host,     'P26 Host',     '+910000000926'),
    (u_member,   'P26 Member',   '+910000000927'),
    (u_outsider, 'P26 Outsider', '+910000000928');

  INSERT INTO public.groups (id, name, host_id) VALUES
    (g_id,    'P26 Test Group', u_host),
    (g_other, 'P26 Other Group', u_outsider);

  -- A trigger on public.groups already enrols the host as a member.
  INSERT INTO public.members (group_id, user_id, role) VALUES
    (g_id, u_host,   'host'),
    (g_id, u_member, 'member')
  ON CONFLICT (group_id, user_id) DO NOTHING;

  INSERT INTO public.kitty_pools (group_id, month)
  VALUES (g_id, '2099-01')
  RETURNING id INTO v_pool;

  -- Act as the host.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text,
    true
  );

  ------------------------------------------------- 1. record 500, read balance
  c1 := public.record_contribution(v_pool, u_member, 500);

  SELECT total_collected INTO collected FROM public.kitty_pools WHERE id = v_pool;
  IF collected <> 500 THEN
    RAISE EXCEPTION 'P26 FAIL: after record_contribution total_collected = %, expected 500', collected;
  END IF;

  bal := public.get_kitty_balance(v_pool);
  IF (bal->>'collected')::integer <> 500 THEN
    RAISE EXCEPTION 'P26 FAIL: get_kitty_balance collected = %, expected 500', bal->>'collected';
  END IF;
  IF NOT (bal->>'totals_consistent')::boolean THEN
    RAISE EXCEPTION 'P26 FAIL: totals_consistent false before any void';
  END IF;
  IF (
    SELECT (m->>'amount_paid')::integer
    FROM jsonb_array_elements(bal->'members') m
    WHERE (m->>'user_id')::uuid = u_member
  ) <> 500 THEN
    RAISE EXCEPTION 'P26 FAIL: member amount_paid is not 500 before void';
  END IF;
  RAISE NOTICE 'P26 PASS: contribution of 500 recorded, balance reads 500';

  --------------------------------------------------------- 2. void it as host
  voided := public.void_contribution(c1.id, '  duplicate entry  ');

  IF voided.voided_at IS NULL THEN
    RAISE EXCEPTION 'P26 FAIL: void_contribution returned a row with null voided_at';
  END IF;
  IF voided.voided_by IS DISTINCT FROM u_host THEN
    RAISE EXCEPTION 'P26 FAIL: voided_by = %, expected host %', voided.voided_by, u_host;
  END IF;
  IF voided.void_reason IS DISTINCT FROM 'duplicate entry' THEN
    RAISE EXCEPTION 'P26 FAIL: void_reason = %, expected trimmed "duplicate entry"', voided.void_reason;
  END IF;

  -- The row is still present (soft delete, never a hard delete).
  SELECT count(*) INTO row_count
  FROM public.contributions WHERE id = c1.id AND voided_at IS NOT NULL;
  IF row_count <> 1 THEN
    RAISE EXCEPTION 'P26 FAIL: contribution row is gone or not marked voided (count=%)', row_count;
  END IF;

  -- ...and total_collected fell by exactly 500.
  SELECT total_collected INTO collected FROM public.kitty_pools WHERE id = v_pool;
  IF collected <> 0 THEN
    RAISE EXCEPTION 'P26 FAIL: total_collected = % after voiding 500, expected 0 (a fall of exactly 500)', collected;
  END IF;

  bal := public.get_kitty_balance(v_pool);
  IF (bal->>'collected')::integer <> 0 OR (bal->>'balance')::integer <> 0 THEN
    RAISE EXCEPTION 'P26 FAIL: balance after void = %', bal::text;
  END IF;
  IF (bal->>'voided_contributions')::integer <> 1 THEN
    RAISE EXCEPTION 'P26 FAIL: voided_contributions = %, expected 1', bal->>'voided_contributions';
  END IF;
  IF NOT (bal->>'totals_consistent')::boolean THEN
    RAISE EXCEPTION 'P26 FAIL: totals_consistent false after void';
  END IF;
  IF (
    SELECT m->>'status'
    FROM jsonb_array_elements(bal->'members') m
    WHERE (m->>'user_id')::uuid = u_member
  ) <> 'pending' THEN
    RAISE EXCEPTION 'P26 FAIL: member still reads as paid after their only contribution was voided';
  END IF;
  RAISE NOTICE 'P26 PASS: void dropped total_collected by exactly 500, row retained with voided_at set';

  ------------------------------------------------------ 3. already voided / 404
  BEGIN
    voided := public.void_contribution(c1.id, 'again');
    RAISE EXCEPTION 'P26 FAIL: re-voiding the same contribution was allowed';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ALREADY_VOIDED' THEN
      RAISE EXCEPTION 'P26 FAIL: re-void raised "%", expected KITPAT_ALREADY_VOIDED', err;
    END IF;
  END;

  BEGIN
    voided := public.void_contribution(gen_random_uuid(), NULL);
    RAISE EXCEPTION 'P26 FAIL: voiding an unknown contribution id was allowed';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_FOUND' THEN
      RAISE EXCEPTION 'P26 FAIL: unknown id raised "%", expected KITPAT_NOT_FOUND', err;
    END IF;
  END;
  RAISE NOTICE 'P26 PASS: KITPAT_ALREADY_VOIDED and KITPAT_NOT_FOUND raised as stable codes';

  ------------------------------------------------------------ 4. expenses path
  e1 := public.record_expense(v_pool, 450, 'P26 Caterer', 'food');
  SELECT total_spent INTO spent FROM public.kitty_pools WHERE id = v_pool;
  IF spent <> 450 THEN
    RAISE EXCEPTION 'P26 FAIL: total_spent = % after record_expense, expected 450', spent;
  END IF;

  voided_exp := public.void_kitty_expense(e1.id, 'wrong bill');
  IF voided_exp.voided_at IS NULL OR voided_exp.voided_by IS DISTINCT FROM u_host THEN
    RAISE EXCEPTION 'P26 FAIL: kitty expense void did not stamp voided_at/voided_by';
  END IF;

  SELECT total_spent INTO spent FROM public.kitty_pools WHERE id = v_pool;
  IF spent <> 0 THEN
    RAISE EXCEPTION 'P26 FAIL: total_spent = % after voiding 450, expected 0', spent;
  END IF;

  SELECT count(*) INTO row_count FROM public.kitty_expenses WHERE id = e1.id;
  IF row_count <> 1 THEN
    RAISE EXCEPTION 'P26 FAIL: kitty expense row was hard-deleted';
  END IF;
  RAISE NOTICE 'P26 PASS: expense void dropped total_spent by exactly 450, row retained';

  ------------------------------------------------- 5. non-host is rejected
  c_a := public.record_contribution(v_pool, u_member, 100);

  -- A plain member of the group is not the host.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', u_member::text, 'role', 'authenticated')::text,
    true
  );
  BEGIN
    voided := public.void_contribution(c_a.id, 'not mine to void');
    RAISE EXCEPTION 'P26 FAIL: a non-host group member was allowed to void a contribution';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_HOST' THEN
      RAISE EXCEPTION 'P26 FAIL: non-host member raised "%", expected KITPAT_NOT_HOST', err;
    END IF;
  END;

  -- Someone outside the group entirely.
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', u_outsider::text, 'role', 'authenticated')::text,
    true
  );
  BEGIN
    voided_exp := public.void_kitty_expense(e1.id, 'not mine either');
    RAISE EXCEPTION 'P26 FAIL: an outsider was allowed to void a kitty expense';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_HOST' THEN
      RAISE EXCEPTION 'P26 FAIL: outsider raised "%", expected KITPAT_NOT_HOST', err;
    END IF;
  END;

  -- Nothing moved.
  SELECT total_collected INTO collected FROM public.kitty_pools WHERE id = v_pool;
  IF collected <> 100 THEN
    RAISE EXCEPTION 'P26 FAIL: rejected void still changed total_collected (now %)', collected;
  END IF;
  IF EXISTS (SELECT 1 FROM public.contributions WHERE id = c_a.id AND voided_at IS NOT NULL) THEN
    RAISE EXCEPTION 'P26 FAIL: rejected void still stamped voided_at';
  END IF;
  RAISE NOTICE 'P26 PASS: non-host member and outsider both rejected with KITPAT_NOT_HOST';

  ------------------------------------- 6. totals cannot drift from live rows
  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text,
    true
  );

  c_b := public.record_contribution(v_pool, u_member, 200);
  c_c := public.record_contribution(v_pool, u_host,   300);
  e_a := public.record_expense(v_pool, 250, 'P26 Cake', 'food');
  e_b := public.record_expense(v_pool, 125, 'P26 Decor', 'decor');

  voided     := public.void_contribution(c_b.id, 'refunded');
  voided_exp := public.void_kitty_expense(e_a.id, 'double charge');

  SELECT total_collected, total_spent INTO collected, spent
  FROM public.kitty_pools WHERE id = v_pool;

  SELECT coalesce(sum(amount), 0) INTO live_sum
  FROM public.contributions WHERE pool_id = v_pool AND voided_at IS NULL;
  IF collected <> live_sum THEN
    RAISE EXCEPTION 'P26 FAIL: total_collected % drifted from sum(non-voided contributions) %', collected, live_sum;
  END IF;
  IF collected <> 400 THEN
    RAISE EXCEPTION 'P26 FAIL: expected 100 + 300 = 400 collected, got %', collected;
  END IF;

  SELECT coalesce(sum(amount), 0) INTO live_sum
  FROM public.kitty_expenses WHERE pool_id = v_pool AND voided_at IS NULL;
  IF spent <> live_sum THEN
    RAISE EXCEPTION 'P26 FAIL: total_spent % drifted from sum(non-voided expenses) %', spent, live_sum;
  END IF;
  IF spent <> 125 THEN
    RAISE EXCEPTION 'P26 FAIL: expected 125 spent, got %', spent;
  END IF;

  bal := public.get_kitty_balance(v_pool);
  IF NOT (bal->>'totals_consistent')::boolean THEN
    RAISE EXCEPTION 'P26 FAIL: get_kitty_balance reports totals_consistent=false';
  END IF;
  IF (bal->>'balance')::integer <> 275 THEN
    RAISE EXCEPTION 'P26 FAIL: balance = %, expected 400 - 125 = 275', bal->>'balance';
  END IF;

  -- Every voided row is still on disk.
  SELECT count(*) INTO row_count FROM public.contributions WHERE pool_id = v_pool;
  IF row_count <> 4 THEN
    RAISE EXCEPTION 'P26 FAIL: expected 4 contribution rows (2 of them voided), found %', row_count;
  END IF;
  RAISE NOTICE 'P26 PASS: totals track sum(non-voided rows) exactly across an interleaved record/void sequence';

  ------------------------------------------- 7. direct DELETE must now fail
  SET LOCAL ROLE authenticated;
  BEGIN
    DELETE FROM public.contributions WHERE id = c_c.id;
    delete_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    delete_blocked := true;
  END;
  RESET ROLE;

  IF NOT delete_blocked THEN
    RAISE EXCEPTION 'P26 FAIL: DELETE on public.contributions as authenticated was not rejected with 42501';
  END IF;

  SET LOCAL ROLE authenticated;
  BEGIN
    DELETE FROM public.kitty_expenses WHERE id = e_b.id;
    delete_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    delete_blocked := true;
  END;
  RESET ROLE;

  IF NOT delete_blocked THEN
    RAISE EXCEPTION 'P26 FAIL: DELETE on public.kitty_expenses as authenticated was not rejected with 42501';
  END IF;

  -- Both rows survived the attempts.
  IF NOT EXISTS (SELECT 1 FROM public.contributions WHERE id = c_c.id)
     OR NOT EXISTS (SELECT 1 FROM public.kitty_expenses WHERE id = e_b.id) THEN
    RAISE EXCEPTION 'P26 FAIL: a direct DELETE removed a ledger row';
  END IF;
  RAISE NOTICE 'P26 PASS: direct DELETE as authenticated fails with insufficient_privilege on both ledger tables';

  RAISE NOTICE 'P26 ALL ASSERTIONS PASSED';
END;
$p26$;

ROLLBACK;
