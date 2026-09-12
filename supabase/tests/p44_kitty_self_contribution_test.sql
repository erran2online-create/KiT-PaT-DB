-- P44 test: record_contribution's split self/host permission,
-- record_expense's unchanged host-only permission, both functions' new
-- KITPAT_* codes, and that no plain-English exception string remains in
-- either function body.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has this migration
-- (20260910040000_p44_kitty_self_contribution.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p44_kitty_self_contribution_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. A non-host member CAN record a contribution for herself, and the
--      pool total re-settles correctly.
--   b. The same member CANNOT record a contribution for another member --
--      KITPAT_INSUFFICIENT_ROLE.
--   c. The host CAN still record against any member.
--   d. An outsider (not in the group at all) CANNOT record anything, even
--      for herself -- KITPAT_INSUFFICIENT_ROLE.
--   e. record_expense still raises KITPAT_INSUFFICIENT_ROLE for a
--      non-host.
--   f. Both functions raise KITPAT_INVALID_AMOUNT for zero/negative
--      amounts, and KITPAT_NOT_FOUND for a missing pool.
--   g. Neither function body contains a remaining plain-English exception
--      string.

BEGIN;

DO $t$
DECLARE
  host_id uuid;
  member_a_id uuid;
  member_b_id uuid;
  outsider_id uuid;
  group_id uuid;
  pool_id uuid;
  missing_pool_id uuid := gen_random_uuid();
  err text;
  contrib_row public.contributions;
  pool_row public.kitty_pools;
  bad_string_count integer;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (name, phone, city) VALUES ('P44 Host', '9922000001', 'Pune') RETURNING id INTO host_id;
  INSERT INTO public.users (name, phone, city) VALUES ('P44 Member A', '9922000002', 'Pune') RETURNING id INTO member_a_id;
  INSERT INTO public.users (name, phone, city) VALUES ('P44 Member B', '9922000003', 'Pune') RETURNING id INTO member_b_id;
  INSERT INTO public.users (name, phone, city) VALUES ('P44 Outsider', '9922000004', 'Pune') RETURNING id INTO outsider_id;

  INSERT INTO public.groups (name, host_id, city) VALUES ('P44 Test Group ' || substr(gen_random_uuid()::text, 1, 8), host_id, 'Pune') RETURNING id INTO group_id;
  INSERT INTO public.members (group_id, user_id, role) VALUES
    (group_id, host_id, 'host'),
    (group_id, member_a_id, 'member'),
    (group_id, member_b_id, 'member');

  INSERT INTO public.kitty_pools (group_id, month, total_collected, total_spent)
  VALUES (group_id, to_char(now(), 'YYYY-MM'), 0, 0)
  RETURNING id INTO pool_id;

  ------------------------------------------------- a. self-recording by a member
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_a_id::text, 'role', 'authenticated')::text, true);
  contrib_row := public.record_contribution(pool_id, member_a_id, 250);
  IF contrib_row.id IS NULL OR contrib_row.user_id <> member_a_id OR contrib_row.amount <> 250 THEN
    RAISE EXCEPTION 'FAIL: a non-host member could not record her own contribution: %', contrib_row;
  END IF;

  SELECT * INTO pool_row FROM public.kitty_pools WHERE id = pool_id;
  IF pool_row.total_collected <> 250 THEN
    RAISE EXCEPTION 'FAIL: pool total_collected = %, expected 250 after the self-recorded contribution', pool_row.total_collected;
  END IF;
  RAISE NOTICE 'PASS: a non-host member can record her own contribution, and the pool total re-settles correctly';

  ------------------------------------------------- b. member cannot record for another
  BEGIN
    PERFORM public.record_contribution(pool_id, member_b_id, 100);
    RAISE EXCEPTION 'FAIL: a non-host member recorded a contribution for another member';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN
      RAISE EXCEPTION 'FAIL: member-for-another record_contribution raised "%", expected KITPAT_INSUFFICIENT_ROLE', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: a member cannot record a contribution for another member';

  ------------------------------------------------- c. host can still record for anyone
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', host_id::text, 'role', 'authenticated')::text, true);
  contrib_row := public.record_contribution(pool_id, member_b_id, 300);
  IF contrib_row.id IS NULL OR contrib_row.user_id <> member_b_id THEN
    RAISE EXCEPTION 'FAIL: the host could not record a contribution for member_b: %', contrib_row;
  END IF;
  RAISE NOTICE 'PASS: the host can still record a contribution against any member';

  --------------------------------------------------- d. outsider cannot record, even for self
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', outsider_id::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.record_contribution(pool_id, outsider_id, 50);
    RAISE EXCEPTION 'FAIL: an outsider recorded a contribution for herself';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN
      RAISE EXCEPTION 'FAIL: outsider self-record raised "%", expected KITPAT_INSUFFICIENT_ROLE', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: a user who is not in the group at all cannot record anything, even for herself';

  --------------------------------------------------- e. record_expense still host-only
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', member_a_id::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.record_expense(pool_id, 100);
    RAISE EXCEPTION 'FAIL: a non-host member recorded an expense';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN
      RAISE EXCEPTION 'FAIL: non-host record_expense raised "%", expected KITPAT_INSUFFICIENT_ROLE', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: record_expense still raises KITPAT_INSUFFICIENT_ROLE for a non-host';

  ------------------------------------------------------- f. amount + not-found codes
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', host_id::text, 'role', 'authenticated')::text, true);

  BEGIN
    PERFORM public.record_contribution(pool_id, host_id, 0);
    RAISE EXCEPTION 'FAIL: record_contribution accepted a zero amount';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INVALID_AMOUNT' THEN
      RAISE EXCEPTION 'FAIL: zero-amount record_contribution raised "%", expected KITPAT_INVALID_AMOUNT', err;
    END IF;
  END;

  BEGIN
    PERFORM public.record_contribution(pool_id, host_id, -50);
    RAISE EXCEPTION 'FAIL: record_contribution accepted a negative amount';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INVALID_AMOUNT' THEN
      RAISE EXCEPTION 'FAIL: negative-amount record_contribution raised "%", expected KITPAT_INVALID_AMOUNT', err;
    END IF;
  END;

  BEGIN
    PERFORM public.record_contribution(missing_pool_id, host_id, 50);
    RAISE EXCEPTION 'FAIL: record_contribution accepted a missing pool id';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_FOUND' THEN
      RAISE EXCEPTION 'FAIL: missing-pool record_contribution raised "%", expected KITPAT_NOT_FOUND', err;
    END IF;
  END;

  BEGIN
    PERFORM public.record_expense(pool_id, 0);
    RAISE EXCEPTION 'FAIL: record_expense accepted a zero amount';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INVALID_AMOUNT' THEN
      RAISE EXCEPTION 'FAIL: zero-amount record_expense raised "%", expected KITPAT_INVALID_AMOUNT', err;
    END IF;
  END;

  BEGIN
    PERFORM public.record_expense(pool_id, -25);
    RAISE EXCEPTION 'FAIL: record_expense accepted a negative amount';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INVALID_AMOUNT' THEN
      RAISE EXCEPTION 'FAIL: negative-amount record_expense raised "%", expected KITPAT_INVALID_AMOUNT', err;
    END IF;
  END;

  BEGIN
    PERFORM public.record_expense(missing_pool_id, 50);
    RAISE EXCEPTION 'FAIL: record_expense accepted a missing pool id';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_FOUND' THEN
      RAISE EXCEPTION 'FAIL: missing-pool record_expense raised "%", expected KITPAT_NOT_FOUND', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: both functions raise KITPAT_INVALID_AMOUNT for zero/negative amounts and KITPAT_NOT_FOUND for a missing pool';

  ------------------------------------------------- g. no remaining English strings
  SELECT count(*) INTO bad_string_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname IN ('record_contribution', 'record_expense')
    AND (
      p.prosrc LIKE '%Host access required%'
      OR p.prosrc LIKE '%Authentication required%'
      OR p.prosrc LIKE '%Amount must be positive%'
      OR p.prosrc LIKE '%Pool not found%'
    );
  IF bad_string_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % plain-English exception string(s) remain in record_contribution/record_expense', bad_string_count;
  END IF;
  RAISE NOTICE 'PASS: no plain-English exception string remains in either function body';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
