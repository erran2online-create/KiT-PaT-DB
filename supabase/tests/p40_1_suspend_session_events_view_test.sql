-- P40.1 test: public.session_events view suspended to service_role only.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P40.1 migration
-- (20260906020000_p40_1_suspend_session_events_view.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p40_1_suspend_session_events_view_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. public.session_events still exists (kept for possible future use,
--      not dropped).
--   2. It has security_invoker = true.
--   3. anon holds none of SELECT/INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/
--      TRIGGER on it.
--   4. authenticated holds none of those privileges either.
--   5. service_role can still SELECT from it.
--
-- Does not touch public.game_events (covered by the separate P40 test) or
-- any game-engine RPC.

BEGIN;

DO $t$
DECLARE
  invoker_on boolean;
  row_count integer;
BEGIN
  ------------------------------------------------------------------ 1. exists
  IF to_regclass('public.session_events') IS NULL THEN
    RAISE EXCEPTION 'FAIL: public.session_events no longer exists -- it should be kept, not dropped';
  END IF;
  RAISE NOTICE 'PASS: public.session_events still exists';

  --------------------------------------------------------- 2. security_invoker
  SELECT 'security_invoker=true' = ANY (c.reloptions)
    INTO invoker_on
  FROM pg_class c
  WHERE c.oid = 'public.session_events'::regclass;

  IF invoker_on IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: public.session_events security_invoker is not true (reloptions did not contain security_invoker=true)';
  END IF;
  RAISE NOTICE 'PASS: public.session_events has security_invoker = true';

  ------------------------------------------------------------- 3 & 4. grants
  IF has_table_privilege('anon', 'public.session_events', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
    RAISE EXCEPTION 'FAIL: anon still holds at least one privilege on public.session_events';
  END IF;
  RAISE NOTICE 'PASS: anon holds no privileges at all on public.session_events';

  IF has_table_privilege('authenticated', 'public.session_events', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER') THEN
    RAISE EXCEPTION 'FAIL: authenticated still holds at least one privilege on public.session_events';
  END IF;
  RAISE NOTICE 'PASS: authenticated holds no privileges at all on public.session_events';

  --------------------------------------------------------- 5. service_role reads
  SET LOCAL ROLE service_role;
  SELECT count(*) INTO row_count FROM public.session_events;
  RESET ROLE;
  RAISE NOTICE 'PASS: service_role can still SELECT from public.session_events (returned % rows without error)', row_count;

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
