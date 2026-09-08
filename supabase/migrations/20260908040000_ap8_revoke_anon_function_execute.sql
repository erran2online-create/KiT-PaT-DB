-- ---------------------------------------------------------------------------
-- AP8: deny-by-default EXECUTE for anon on schema public functions, with an
-- explicit, documented allow-list, plus a root-cause fix so future
-- migrations do not reintroduce the gap.
--
-- PROBLEM (verified by reproduction on PostgreSQL; ACLs inspected -- and
-- confirmed against this repo's own baseline dump,
-- 20260801140136_remote_schema.sql lines 5165-5171): Supabase ran
-- `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL
-- ON FUNCTIONS TO anon, authenticated, service_role` once, at project
-- creation. That writes an EXPLICIT anon=X/postgres entry into every
-- function's proacl at CREATE time. This repo's standing pattern --
-- `REVOKE ALL ON FUNCTION ... FROM PUBLIC` followed by `GRANT EXECUTE ...
-- TO authenticated, service_role` -- removes only PostgreSQL's built-in
-- PUBLIC pseudo-role grant. It does NOT touch the separate, explicit anon
-- grant: has_function_privilege('anon', ..., 'EXECUTE') stays true.
-- Reproduced: a function created under the default privilege still shows
-- anon EXECUTE = true after REVOKE ALL FROM PUBLIC; a function created
-- after the default privilege is revoked shows false.
--
-- CONSEQUENCE: anon holds EXECUTE on essentially every SECURITY DEFINER
-- function in public, including the whole admin surface (is_admin,
-- admin_role, is_admin_owner, admin_can_write, admin_list_users,
-- admin_request_reveal, admin_confirm_reveal, admin_list_plans,
-- admin_list_subscriptions, admin_plan_change_impact, and the AP7
-- group/ledger RPCs). Each has its own internal is_admin()/is_admin_owner()
-- guard, and an anon JWT carries no email claim, so every one of them
-- already returns KITPAT_ADMIN_ONLY / KITPAT_INSUFFICIENT_ROLE for anon --
-- this is a missing SECOND lock, not an open door. Fixed anyway.
--
-- FIX, three parts:
--   1. SWEEP (below): revoke anon EXECUTE from every function that
--      currently exists in schema public and is not on the allow-list.
--   2. ROOT CAUSE (below): `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN
--      SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon`, so a FUTURE
--      function never receives the grant at CREATE time in the first
--      place. Scoped to role postgres (the role a migration runs as) and
--      to schema public only -- it does not touch tables, sequences, or
--      any other schema.
--
--      AP8.1 CORRECTION: this scoping is INCOMPLETE IN PRINCIPLE, not
--      total. The dump's commented-out supabase_admin default-privilege
--      line is not authoritative -- it only reflects what pg_dump chose
--      to emit as a comment, not the live catalog. Checked directly
--      against the live database (pg_default_acl): a supabase_admin
--      default ACL for public functions EXISTS ALONGSIDE postgres's,
--      granting anon,authenticated,service_role too. This statement
--      cannot reach that second default ACL --
--      `ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin ...` would
--      require postgres to be a member of supabase_admin
--      (pg_has_role('postgres','supabase_admin','MEMBER') is false, live
--      -confirmed), so it is deliberately NOT attempted here -- it would
--      raise a permission error and abort the whole migration.
--
--      In PRACTICE, for this repo, the fix is total anyway: every one of
--      the 109 functions currently in schema public is owned by postgres
--      (live-confirmed: distinct owner count = 1), and `supabase db push`
--      runs migrations as postgres, so every function this repo ever
--      creates is covered by the one default ACL this statement can
--      reach. The gap only matters if something someday creates a
--      public function as supabase_admin (e.g. directly via the
--      Supabase dashboard/support tooling, not through a migration) --
--      that function would need its anon grant revoked by hand (or via
--      a future migration's explicit REVOKE, same as the sweep above
--      does today for existing functions).
--   3. RE-ASSERT the two allow-listed grants at the end, so this file's
--      three sections are order-independent.
--
-- ALLOW-LIST -- every function anywhere in this repo's migration history
-- explicitly GRANTed to anon, confirmed by grepping every file in
-- supabase/migrations for `TO anon` and `, anon`. These two are the ONLY
-- hits; no other anon function grant exists to classify or flag:
--   - public.preview_group_invite(text) -- P28, 20260823130000 line 334.
--     Called signed-out by the member frontend (src/groups/api.ts) so an
--     invite link renders a group card before signup.
--   - public.get_app_content(text, text) -- AP5, 20260908010000 line 133.
--     Serves legal/website content (privacy policy, terms, etc.) to
--     logged-out visitors -- required for the public Play/App Store
--     review URLs.
--
-- Does NOT change any function body, any RLS policy, any table grant, or
-- anon's SELECT on public.app_content (AP5 line 44) -- this migration only
-- ever issues REVOKE/GRANT EXECUTE ON FUNCTION statements plus the one
-- ALTER DEFAULT PRIVILEGES statement above.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Sweep -- deny-by-default. Loops over every function (prokind = 'f')
--    in schema public; for each one not on the allow-list, revokes anon's
--    EXECUTE. The REVOKE statement itself is built from
--    format('%s', p.oid::regprocedure), so overloaded signatures (e.g. a
--    future second host_create_*_session(...) form) are handled
--    correctly -- the oid, not the bare name, identifies exactly which
--    overload is being revoked. Idempotent: revoking a privilege a role
--    does not hold is a no-op, so re-running this migration is safe.
--    Each revoked function is named via RAISE NOTICE so the exact list
--    this sweep touched can be eyeballed in a real run's server log
--    before merge (see this PR's description for that list).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  r record;
  allowlist text[] := ARRAY[
    'preview_group_invite(text)',
    'get_app_content(text, text)'
  ];
  sig text;
BEGIN
  FOR r IN
    SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
  LOOP
    sig := r.proname || '(' || r.args || ')';
    IF sig = ANY (allowlist) THEN
      CONTINUE;
    END IF;

    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM anon', r.oid::regprocedure);
    RAISE NOTICE 'AP8: revoked anon EXECUTE on public.%', sig;
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Root cause -- stop future functions inheriting the grant at all.
-- ---------------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon;

-- ---------------------------------------------------------------------------
-- 3. Re-assert the allow-list -- makes this file order-independent
--    regardless of where the sweep and the default-privilege change above
--    land relative to each other.
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION public.preview_group_invite(text) TO anon;
GRANT EXECUTE ON FUNCTION public.get_app_content(text, text) TO anon;
