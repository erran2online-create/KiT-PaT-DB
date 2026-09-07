-- ---------------------------------------------------------------------------
-- AP1: one secure write path for the 7 admin-editable content tables
-- (badge_definitions, invite_templates, plans, game_theme_packs,
-- festival_themes, greeting_variants, tambola_variants), fronted by the
-- new supabase/functions/admin-write edge function.
--
-- Does NOT loosen RLS on any of the 7 tables -- they stay client-read-only.
-- The edge function writes with service_role and bypasses RLS by design.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. admin_can_write(p_table) -- single source of truth for the role/table
--    write rule, callable directly by an admin's own session (so
--    auth.jwt()/is_admin() resolve correctly) and re-checked that way by
--    the edge function as defense in depth.
--
--    member     -> false always (read only)
--    org_admin  -> true for every allow-listed table except plans
--    owner      -> true for every allow-listed table
--    anything else (not an active admin, or table not in the 7) -> false
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_can_write(p_table text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT
    public.is_admin()
    AND p_table = ANY (ARRAY[
      'badge_definitions', 'invite_templates', 'plans', 'game_theme_packs',
      'festival_themes', 'greeting_variants', 'tambola_variants'
    ])
    AND (
      public.admin_role() = 'owner'
      OR (public.admin_role() = 'org_admin' AND p_table <> 'plans')
    );
$$;

COMMENT ON FUNCTION public.admin_can_write(text) IS
  'True if the caller is an active admin whose role permits writing p_table: owner writes all 7 admin content tables, org_admin writes all except plans, member never writes. The one place this rule is defined -- the admin-write edge function re-checks it as defense in depth.';

REVOKE ALL ON FUNCTION public.admin_can_write(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_can_write(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. log_admin_action -- add two trailing optional actor-override params.
--
-- AP0's version resolves the actor purely from auth.jwt()->>'email',
-- which only works when the function is called directly within an actual
-- admin's own authenticated session. The admin-write edge function calls
-- this via its service_role client so log_admin_action's own internal
-- guard passes (current_setting('role') = 'service_role') -- but that
-- client's JWT carries no 'email' claim, so auth.jwt()->>'email' resolves
-- to NULL in that context, and every edge-function-driven audit row would
-- otherwise have a NULL actor, defeating the point of an audit log.
--
-- p_actor_admin_id / p_actor_email are optional and trailing, so every
-- existing positional call (8 args) is unaffected: when omitted, behaviour
-- is byte-identical to AP0 (auto-detect via auth.jwt()). When the caller
-- already knows the acting admin's identity -- as the edge function does,
-- having just verified it via auth.getUser() + an admins lookup -- it can
-- pass them explicitly instead of relying on JWT auto-detection.
--
-- This is a new migration (not an edit to AP0's file); the old 8-arg
-- signature is dropped and replaced with this 10-arg one, exactly the
-- DROP FUNCTION IF EXISTS + CREATE pattern used elsewhere in this repo
-- (e.g. host_create_tambola_session in P25) to add a new signature without
-- ever touching a prior migration file.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.log_admin_action(text, text, text, jsonb, jsonb, boolean, text, text);

CREATE FUNCTION public.log_admin_action(
  p_action text,
  p_target_type text,
  p_target_id text,
  p_before jsonb,
  p_after jsonb,
  p_is_sensitive_reveal boolean DEFAULT false,
  p_revealed_field text DEFAULT NULL,
  p_revealed_subject text DEFAULT NULL,
  p_actor_admin_id uuid DEFAULT NULL,
  p_actor_email text DEFAULT NULL
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

  IF p_actor_admin_id IS NOT NULL OR p_actor_email IS NOT NULL THEN
    caller_admin_id := p_actor_admin_id;
    caller_email := p_actor_email;
  ELSE
    caller_email := auth.jwt() ->> 'email';
    IF caller_email IS NOT NULL THEN
      SELECT id INTO caller_admin_id FROM public.admins WHERE email = caller_email;
    END IF;
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

COMMENT ON FUNCTION public.log_admin_action(text, text, text, jsonb, jsonb, boolean, text, text, uuid, text) IS
  'service_role only (checked via current_setting(''role'') or the caller''s JWT role claim). Inserts one admin_audit row. Actor is p_actor_admin_id/p_actor_email when explicitly given (the admin-write edge function''s path), else auto-detected from the caller''s own auth.jwt()->>''email'' (AP0''s original direct-session path). Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.log_admin_action(text, text, text, jsonb, jsonb, boolean, text, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_admin_action(text, text, text, jsonb, jsonb, boolean, text, text, uuid, text) TO authenticated, service_role;
