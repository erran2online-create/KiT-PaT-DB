-- AP8 test: anon holds EXECUTE on the two allow-listed public functions and
-- NOTHING else in schema public; the admin surface specifically; that the
-- sweep did not over-revoke authenticated/service_role; and that the
-- root-cause default-privilege fix is live for brand-new functions.
--
-- Self-contained and non-destructive: the throwaway-function part (f)
-- happens inside one transaction that is ROLLED BACK at the end. Items
-- a-e are plain SELECTs against already-committed privilege state (the
-- REVOKE/GRANT/ALTER DEFAULT PRIVILEGES statements are DDL applied by the
-- migration itself, not something this test transaction could roll back
-- even if it wanted to) so they are safe to run inside the same
-- transaction as f without side effects.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap8_revoke_anon_function_execute_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a/b. anon still holds EXECUTE on the two allow-listed functions
--        (preview_group_invite, get_app_content) -- the signed-out paths
--        that need it keep working.
--   c. anon holds EXECUTE on NONE of the listed admin-surface functions.
--   d. Blanket: zero functions in schema public grant EXECUTE to anon
--      except the allow-list -- fails with the offending names if any
--      other exists.
--   e. authenticated and service_role still hold EXECUTE on a sample of
--      the revoked functions (the sweep did not over-revoke).
--   f. A throwaway function created inside this test, after
--      `REVOKE ALL ... FROM PUBLIC` (this repo's standing pattern), has
--      NO anon EXECUTE at all -- proving the root-cause default-privilege
--      fix is live, not just the one-time sweep.

BEGIN;

-- Item f's fixture: CREATE FUNCTION / REVOKE ALL are top-level DDL
-- statements, not valid directly inside a PL/pgSQL block body, so they run
-- here (still inside this same transaction, still rolled back at the end)
-- and are only READ from inside the DO block below via
-- has_function_privilege().
CREATE FUNCTION public.ap8_test_throwaway_fn() RETURNS boolean LANGUAGE sql AS $fn$ SELECT true $fn$;

-- This repo's standing pattern -- REVOKE ALL FROM PUBLIC, nothing anon
-- -specific. Before AP8's root-cause fix, this alone left anon with
-- EXECUTE (the bug this whole migration exists to close). After it, a
-- brand-new function never receives the anon grant in the first place.
REVOKE ALL ON FUNCTION public.ap8_test_throwaway_fn() FROM PUBLIC;

DO $t$
DECLARE
  offending_functions text[];
  sample_fn text;
  sample_fns text[] := ARRAY[
    'is_admin()',
    'admin_can_write(text)',
    'admin_list_groups(text,int,int)',
    'log_admin_action(text,text,text,jsonb,jsonb,boolean,text,text,uuid,text)'
  ];
BEGIN
  ----------------------------------------------------- a/b. allow-list keeps EXECUTE
  IF has_function_privilege('anon', 'public.preview_group_invite(text)', 'EXECUTE') IS NOT true THEN
    RAISE EXCEPTION 'FAIL: anon lost EXECUTE on public.preview_group_invite(text) -- the signed-out invite-link path would break';
  END IF;
  IF has_function_privilege('anon', 'public.get_app_content(text,text)', 'EXECUTE') IS NOT true THEN
    RAISE EXCEPTION 'FAIL: anon lost EXECUTE on public.get_app_content(text,text) -- signed-out legal/website content would break';
  END IF;
  RAISE NOTICE 'PASS: anon retains EXECUTE on both allow-listed functions';

  ------------------------------------------------------ c. admin surface revoked
  IF has_function_privilege('anon', 'public.is_admin()', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.is_admin()';
  END IF;
  IF has_function_privilege('anon', 'public.admin_role()', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_role()';
  END IF;
  IF has_function_privilege('anon', 'public.is_admin_owner()', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.is_admin_owner()';
  END IF;
  IF has_function_privilege('anon', 'public.admin_can_write(text)', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_can_write(text)';
  END IF;
  IF has_function_privilege('anon', 'public.admin_list_users(text,int,int)', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_list_users(text,int,int)';
  END IF;
  IF has_function_privilege('anon', 'public.admin_request_reveal(uuid,text)', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_request_reveal(uuid,text)';
  END IF;
  IF has_function_privilege('anon', 'public.admin_confirm_reveal(uuid,text)', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_confirm_reveal(uuid,text)';
  END IF;
  IF has_function_privilege('anon', 'public.admin_list_groups(text,int,int)', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_list_groups(text,int,int)';
  END IF;
  IF has_function_privilege('anon', 'public.admin_group_detail(uuid)', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_group_detail(uuid)';
  END IF;
  IF has_function_privilege('anon', 'public.admin_list_ledger(uuid)', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_list_ledger(uuid)';
  END IF;
  IF has_function_privilege('anon', 'public.admin_void_ledger_entry(uuid,text,text)', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.admin_void_ledger_entry(uuid,text,text)';
  END IF;
  IF has_function_privilege(
    'anon',
    'public.log_admin_action(text,text,text,jsonb,jsonb,boolean,text,text,uuid,text)',
    'EXECUTE'
  ) IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on public.log_admin_action(...)';
  END IF;
  RAISE NOTICE 'PASS: anon holds EXECUTE on none of the admin-surface functions';

  ------------------------------------------------------------ d. blanket sweep proof
  SELECT array_agg(sig ORDER BY sig) INTO offending_functions
  FROM (
    SELECT DISTINCT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    CROSS JOIN LATERAL aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
    JOIN pg_roles gr ON gr.oid = a.grantee
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND gr.rolname = 'anon'
      AND a.privilege_type = 'EXECUTE'
  ) x
  WHERE sig NOT IN ('preview_group_invite(text)', 'get_app_content(text, text)');

  IF offending_functions IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: % function(s) in schema public grant EXECUTE to anon outside the allow-list: %', array_length(offending_functions, 1), offending_functions;
  END IF;
  RAISE NOTICE 'PASS: zero functions in schema public grant anon EXECUTE except the two allow-listed ones';

  -------------------------------------------------- e. authenticated/service_role intact
  FOREACH sample_fn IN ARRAY sample_fns LOOP
    IF has_function_privilege('authenticated', 'public.' || sample_fn, 'EXECUTE') IS NOT true THEN
      RAISE EXCEPTION 'FAIL: authenticated lost EXECUTE on public.% -- the sweep over-revoked', sample_fn;
    END IF;
    IF has_function_privilege('service_role', 'public.' || sample_fn, 'EXECUTE') IS NOT true THEN
      RAISE EXCEPTION 'FAIL: service_role lost EXECUTE on public.% -- the sweep over-revoked', sample_fn;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: authenticated and service_role still hold EXECUTE on a sample of the revoked functions';

  ---------------------------------------------- f. root-cause default-privilege fix
  IF has_function_privilege('anon', 'public.ap8_test_throwaway_fn()', 'EXECUTE') IS NOT false THEN
    RAISE EXCEPTION 'FAIL: a brand-new function still received anon EXECUTE by default -- the ALTER DEFAULT PRIVILEGES fix is not live';
  END IF;
  RAISE NOTICE 'PASS: a throwaway function created after this migration has no anon EXECUTE at all, proving the default-privilege root-cause fix is live';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
