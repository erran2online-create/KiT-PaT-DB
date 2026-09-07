-- ---------------------------------------------------------------------------
-- AP0: admin auth + audit foundation, plus a small plan-name content fix.
--
-- Admin is a separate frontend later; this shares the ONE database.
--
-- public.admins already exists (id, user_id, role default 'admin' CHECK IN
-- superadmin/admin/support, permissions jsonb, created_at, created_by),
-- with RLS enabled and an existing "admins_superadmin_only" (ALL commands,
-- keyed off user_id/role) policy, and GRANT ALL to anon/authenticated. This
-- migration reshapes it to an email/role-based model additively -- no
-- existing column (user_id, permissions, created_by) or row is dropped.
--
-- Assumption, stated for the record: this reshape adds email NOT NULL and
-- a new, disjoint role CHECK (owner/org_admin/member replacing
-- superadmin/admin/support) with no backfill step, because the task
-- describes admins as having "0 admin functions" -- i.e. no application
-- code has ever existed to populate it with real rows. If that assumption
-- is wrong and admins already holds rows, this migration fails safely at
-- apply time (the whole transaction rolls back, no partial application,
-- no data loss) rather than silently corrupting or dropping anything.
--
-- public.admin_logs is explicitly left untouched, per the task, including
-- its existing admin_logs_admins_only policy (which still reads
-- admins.user_id -- untouched and still present).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. admins -- reshape additively
-- ---------------------------------------------------------------------------
ALTER TABLE public.admins
  ADD COLUMN IF NOT EXISTS email text,
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS last_login_at timestamptz;

ALTER TABLE public.admins ALTER COLUMN role SET DEFAULT 'member';
ALTER TABLE public.admins ALTER COLUMN email SET NOT NULL;

ALTER TABLE public.admins DROP CONSTRAINT IF EXISTS admins_role_check;
ALTER TABLE public.admins ADD CONSTRAINT admins_role_check
  CHECK (role IN ('owner', 'org_admin', 'member'));

ALTER TABLE public.admins DROP CONSTRAINT IF EXISTS admins_email_domain_check;
ALTER TABLE public.admins ADD CONSTRAINT admins_email_domain_check
  CHECK (email LIKE '%@kitpat.in');

ALTER TABLE public.admins DROP CONSTRAINT IF EXISTS admins_email_key;
ALTER TABLE public.admins ADD CONSTRAINT admins_email_key UNIQUE (email);

COMMENT ON TABLE public.admins IS
  'Office admins (role: owner/org_admin/member), identified by @kitpat.in email. Client-writable only via service_role; see is_admin()/admin_role()/is_admin_owner().';

-- ---------------------------------------------------------------------------
-- 2. Helper RPCs -- defined before the admins RLS policy, which uses is_admin()
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admins a
    WHERE a.email = (auth.jwt() ->> 'email') AND a.is_active = true
  );
$$;

COMMENT ON FUNCTION public.is_admin() IS
  'True if an active admins row exists whose email matches the caller''s JWT email.';

CREATE OR REPLACE FUNCTION public.admin_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT a.role FROM public.admins a
  WHERE a.email = (auth.jwt() ->> 'email') AND a.is_active = true
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.admin_role() IS
  'The caller''s active admins.role (owner/org_admin/member), or NULL if they are not an active admin.';

CREATE OR REPLACE FUNCTION public.is_admin_owner()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT coalesce(public.admin_role() = 'owner', false);
$$;

COMMENT ON FUNCTION public.is_admin_owner() IS
  'True if the caller is an active admin with role=owner.';

REVOKE ALL ON FUNCTION public.is_admin() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_role() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_admin_owner() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_role() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_admin_owner() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. admins grants + RLS -- SELECT only; client writes go through
--    service_role (a future admin edge function).
-- ---------------------------------------------------------------------------
REVOKE ALL ON public.admins FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.admins FROM authenticated;
GRANT SELECT ON public.admins TO authenticated;

DROP POLICY IF EXISTS "admins_superadmin_only" ON public.admins;
DROP POLICY IF EXISTS admins_read ON public.admins;
CREATE POLICY admins_read ON public.admins
  FOR SELECT TO authenticated
  USING (email = (auth.jwt() ->> 'email') OR public.is_admin());

-- ---------------------------------------------------------------------------
-- 4. Seed the first owner
-- ---------------------------------------------------------------------------
INSERT INTO public.admins (email, role, is_active)
VALUES ('aps@kitpat.in', 'owner', true)
ON CONFLICT (email) DO UPDATE SET role = 'owner', is_active = true;

-- ---------------------------------------------------------------------------
-- 5. admin_audit -- new table, RLS: active admins read non-reveal rows,
--    owners read everything.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admin_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_admin_id uuid,
  actor_email text,
  action text NOT NULL,
  target_type text,
  target_id text,
  before jsonb,
  after jsonb,
  is_sensitive_reveal boolean NOT NULL DEFAULT false,
  revealed_field text,
  revealed_subject text,
  created_at timestamptz DEFAULT now()
);

COMMENT ON TABLE public.admin_audit IS
  'Admin action audit log. is_sensitive_reveal rows (e.g. revealing a user''s PII) are readable only by owners; every other row is readable by any active admin. Written only via log_admin_action (service_role guarded).';

ALTER TABLE public.admin_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS admin_audit_read ON public.admin_audit;
CREATE POLICY admin_audit_read ON public.admin_audit
  FOR SELECT TO authenticated
  USING (
    public.is_admin()
    AND (is_sensitive_reveal = false OR public.is_admin_owner())
  );

GRANT SELECT ON public.admin_audit TO authenticated;
GRANT ALL ON public.admin_audit TO service_role;

-- ---------------------------------------------------------------------------
-- 6. log_admin_action -- service_role only (checked internally, not just by
--    grant, since a caller may reach this RPC as `authenticated` carrying a
--    service_role JWT claim).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_admin_action(
  p_action text,
  p_target_type text,
  p_target_id text,
  p_before jsonb,
  p_after jsonb,
  p_is_sensitive_reveal boolean DEFAULT false,
  p_revealed_field text DEFAULT NULL,
  p_revealed_subject text DEFAULT NULL
) RETURNS public.admin_audit
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_email text;
  caller_admin_id uuid;
  row_out public.admin_audit;
BEGIN
  IF NOT coalesce(
    current_setting('role', true) = 'service_role'
    OR (auth.jwt() ->> 'role') = 'service_role',
    false
  ) THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  caller_email := auth.jwt() ->> 'email';
  IF caller_email IS NOT NULL THEN
    SELECT id INTO caller_admin_id FROM public.admins WHERE email = caller_email;
  END IF;

  INSERT INTO public.admin_audit (
    actor_admin_id, actor_email, action, target_type, target_id,
    before, after, is_sensitive_reveal, revealed_field, revealed_subject
  ) VALUES (
    caller_admin_id, caller_email, p_action, p_target_type, p_target_id,
    p_before, p_after, coalesce(p_is_sensitive_reveal, false), p_revealed_field, p_revealed_subject
  ) RETURNING * INTO row_out;

  RETURN row_out;
END;
$$;

COMMENT ON FUNCTION public.log_admin_action(text, text, text, jsonb, jsonb, boolean, text, text) IS
  'service_role only (checked via current_setting(''role'') or the caller''s JWT role claim). Inserts one admin_audit row, resolving actor_admin_id/actor_email from the caller''s admins record where possible. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.log_admin_action(text, text, text, jsonb, jsonb, boolean, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_admin_action(text, text, text, jsonb, jsonb, boolean, text, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Plan name neutraliser -- Empress/Queen are gendered. name/slug stay
--    untouched (billing + frontend reference them); Free/Starter are
--    already neutral and are left alone.
-- ---------------------------------------------------------------------------
ALTER TABLE public.plans
  ADD COLUMN IF NOT EXISTS name_neutral text,
  ADD COLUMN IF NOT EXISTS name_variant_female text,
  ADD COLUMN IF NOT EXISTS name_variant_male text;

UPDATE public.plans
SET name_neutral = 'Elite', name_variant_female = 'Empress', name_variant_male = 'Emperor'
WHERE name = 'Empress';

UPDATE public.plans
SET name_neutral = 'Champion', name_variant_female = 'Queen', name_variant_male = 'King'
WHERE name = 'Queen';
