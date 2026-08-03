-- Harden public.users: anon must not mutate (or even SELECT) any row.
-- Authenticated users may only SELECT/UPDATE/INSERT their own row via RLS.

REVOKE ALL ON TABLE public.users FROM anon;

-- Keep authenticated privileges narrow; RLS still gates by auth.uid() = id
REVOKE ALL ON TABLE public.users FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.users TO authenticated;
GRANT ALL ON TABLE public.users TO service_role;

-- Recreate own-row policies explicitly (idempotent)
DROP POLICY IF EXISTS "users_read_own" ON public.users;
CREATE POLICY "users_read_own" ON public.users
  FOR SELECT TO authenticated
  USING ((SELECT auth.uid()) = id);

DROP POLICY IF EXISTS "users_update_own" ON public.users;
CREATE POLICY "users_update_own" ON public.users
  FOR UPDATE TO authenticated
  USING ((SELECT auth.uid()) = id)
  WITH CHECK ((SELECT auth.uid()) = id);

DROP POLICY IF EXISTS "users_insert_own" ON public.users;
CREATE POLICY "users_insert_own" ON public.users
  FOR INSERT TO authenticated
  WITH CHECK ((SELECT auth.uid()) = id);
