-- AP1.1 test: stale plans_admin_write policy is gone; plans stays
-- client-read-only.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the AP1.1 migration
-- (20260907020000_ap1_1_drop_stale_plans_write_policy.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap1_1_drop_stale_plans_write_policy_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. No INSERT/UPDATE/DELETE/ALL policy remains on public.plans.
--   2. A direct authenticated INSERT/UPDATE/DELETE on plans each fail.
--   3. plans is still readable by authenticated.

BEGIN;

DO $t$
DECLARE
  write_policy_count integer;
  write_blocked boolean;
  any_plan_id uuid;
  read_count integer;
BEGIN
  --------------------------------------------------------- 1. policy is gone
  SELECT count(*) INTO write_policy_count
  FROM pg_policies
  WHERE schemaname = 'public' AND tablename = 'plans' AND cmd IN ('ALL', 'INSERT', 'UPDATE', 'DELETE');

  IF write_policy_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % INSERT/UPDATE/DELETE/ALL polic(ies) still exist on public.plans, expected 0', write_policy_count;
  END IF;
  RAISE NOTICE 'PASS: no INSERT/UPDATE/DELETE/ALL policy remains on public.plans';

  SELECT id INTO any_plan_id FROM public.plans LIMIT 1;

  --------------------------------------------------- 2. direct writes blocked
  SET LOCAL ROLE authenticated;
  BEGIN
    INSERT INTO public.plans (name, slug, price_monthly, price_yearly) VALUES ('Forged', 'forged', 0, 0);
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: direct INSERT into plans as authenticated was not rejected';
  END IF;

  IF any_plan_id IS NOT NULL THEN
    SET LOCAL ROLE authenticated;
    BEGIN
      UPDATE public.plans SET name = 'Forged' WHERE id = any_plan_id;
      write_blocked := false;
    EXCEPTION WHEN insufficient_privilege THEN
      write_blocked := true;
    END;
    RESET ROLE;
    IF NOT write_blocked THEN
      RAISE EXCEPTION 'FAIL: direct UPDATE on plans as authenticated was not rejected';
    END IF;

    SET LOCAL ROLE authenticated;
    BEGIN
      DELETE FROM public.plans WHERE id = any_plan_id;
      write_blocked := false;
    EXCEPTION WHEN insufficient_privilege THEN
      write_blocked := true;
    END;
    RESET ROLE;
    IF NOT write_blocked THEN
      RAISE EXCEPTION 'FAIL: direct DELETE on plans as authenticated was not rejected';
    END IF;
  ELSE
    RAISE NOTICE 'NOTE: public.plans has no rows to attempt UPDATE/DELETE against -- only INSERT was exercised';
  END IF;
  RAISE NOTICE 'PASS: direct INSERT/UPDATE/DELETE on plans as authenticated all fail';

  ------------------------------------------------------------- 3. still readable
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO read_count FROM public.plans;
  RESET ROLE;
  RAISE NOTICE 'PASS: plans is still readable by authenticated (% rows visible, no error)', read_count;

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
