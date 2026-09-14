-- ---------------------------------------------------------------------------
-- AP16: a soft-delete archive for plans.features keys, so an admin removing
-- a feature key no longer loses it permanently. public.plans was read in
-- full from 20260801140136_remote_schema.sql: features/limits are both
-- jsonb DEFAULT '{}' NOT NULL, name/slug are the plan identity. No
-- migration seeds the live plan rows (Free/Starter/Queen/Empress) --
-- confirmed by grepping every migration for "INSERT INTO.*plans" (nothing)
-- -- they were seeded outside migration history, the same situation as
-- feature_flags/analytics_event_catalog/recipes' pre-existing rows. Their
-- exact live features counts (Free 19 keys, Empress 27, per the task) are
-- therefore not independently verifiable from this repo; the test below
-- proves the migration is additive and never touches an existing features
-- value using its own constructed fixture plans shaped like the real ones
-- (19- and 27-key features objects), rather than asserting against
-- production-only rows this environment cannot see.
--
-- Plan edits are owner-only today (AP6's admin_plan_change_impact /
-- admin_update_plan_limits-shaped RPCs all gate on is_admin_owner()
-- alone) -- both RPCs below match that with the exact same single check,
-- not the two-step ADMIN_ONLY/INSUFFICIENT_ROLE split used elsewhere
-- (AP14/AP15): the task asks for one admin-domain code,
-- KITPAT_INSUFFICIENT_ROLE, covering both "not an admin" and "admin but
-- not owner", exactly as AP2's admin_request_reveal and AP6's
-- admin_plan_change_impact already do for other owner-only plan/reveal
-- actions.
--
-- Neither RPC ever deletes a value outright: each moves a key between
-- plans.features and plans.features_archive in ONE UPDATE statement, so
-- the value is either in one object or the other, never dropped in
-- between.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. plans.features_archive -- additive, defaults '{}' so every existing
--    row (and its untouched features value) is unaffected.
-- ---------------------------------------------------------------------------
ALTER TABLE public.plans
  ADD COLUMN IF NOT EXISTS features_archive jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.plans.features_archive IS
  'Same shape as features: an object of key -> value. Removed feature keys land here with their value intact instead of being deleted outright -- see admin_archive_plan_feature/admin_restore_plan_feature.';

-- ---------------------------------------------------------------------------
-- 2. admin_archive_plan_feature -- owner-only, audited. Moves p_key from
--    features to features_archive, value unchanged, in one UPDATE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_archive_plan_feature(p_plan_id uuid, p_key text)
RETURNS public.plans
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_admin_id uuid;
  caller_email text;
  before_row jsonb;
  row_out public.plans;
  v_value jsonb;
BEGIN
  IF NOT public.is_admin_owner() THEN
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
  END IF;

  SELECT to_jsonb(p) INTO before_row FROM public.plans p WHERE p.id = p_plan_id;
  IF before_row IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  IF NOT (before_row -> 'features' ? p_key) THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
  v_value := before_row -> 'features' -> p_key;

  UPDATE public.plans
  SET features = features - p_key,
      features_archive = features_archive || jsonb_build_object(p_key, v_value)
  WHERE id = p_plan_id
  RETURNING * INTO row_out;

  caller_email := auth.jwt() ->> 'email';
  SELECT id INTO caller_admin_id FROM public.admins WHERE email = caller_email AND is_active = true;

  PERFORM public.log_admin_action(
    'archive:plan_feature', 'plans', p_plan_id::text, before_row, to_jsonb(row_out), false, NULL, NULL, caller_admin_id, caller_email
  );

  RETURN row_out;
END;
$$;

COMMENT ON FUNCTION public.admin_archive_plan_feature(uuid, text) IS
  'Owner-only. Moves p_key (and its value, unchanged) from plans.features to plans.features_archive in one UPDATE -- never deletes a value outright. Audited via log_admin_action. Errors: KITPAT_INSUFFICIENT_ROLE / KITPAT_NOT_FOUND (plan does not exist, or p_key is not currently in features).';

REVOKE ALL ON FUNCTION public.admin_archive_plan_feature(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_archive_plan_feature(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_archive_plan_feature(uuid, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. admin_restore_plan_feature -- owner-only, audited. Moves p_key from
--    features_archive back to features, value unchanged, in one UPDATE.
--    Refuses to overwrite a live value: if p_key already exists in
--    features, KITPAT_ALREADY_EXISTS rather than silently clobbering it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_restore_plan_feature(p_plan_id uuid, p_key text)
RETURNS public.plans
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_admin_id uuid;
  caller_email text;
  before_row jsonb;
  row_out public.plans;
  v_value jsonb;
BEGIN
  IF NOT public.is_admin_owner() THEN
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
  END IF;

  SELECT to_jsonb(p) INTO before_row FROM public.plans p WHERE p.id = p_plan_id;
  IF before_row IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  IF NOT (before_row -> 'features_archive' ? p_key) THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  IF before_row -> 'features' ? p_key THEN
    RAISE EXCEPTION 'KITPAT_ALREADY_EXISTS' USING ERRCODE = 'PT409';
  END IF;
  v_value := before_row -> 'features_archive' -> p_key;

  UPDATE public.plans
  SET features_archive = features_archive - p_key,
      features = features || jsonb_build_object(p_key, v_value)
  WHERE id = p_plan_id
  RETURNING * INTO row_out;

  caller_email := auth.jwt() ->> 'email';
  SELECT id INTO caller_admin_id FROM public.admins WHERE email = caller_email AND is_active = true;

  PERFORM public.log_admin_action(
    'restore:plan_feature', 'plans', p_plan_id::text, before_row, to_jsonb(row_out), false, NULL, NULL, caller_admin_id, caller_email
  );

  RETURN row_out;
END;
$$;

COMMENT ON FUNCTION public.admin_restore_plan_feature(uuid, text) IS
  'Owner-only. Moves p_key (and its value, unchanged) from plans.features_archive back to plans.features in one UPDATE. Refuses to overwrite a live value: KITPAT_ALREADY_EXISTS if p_key already exists in features. Audited via log_admin_action. Errors: KITPAT_INSUFFICIENT_ROLE / KITPAT_NOT_FOUND (plan does not exist, or p_key is not currently archived) / KITPAT_ALREADY_EXISTS.';

REVOKE ALL ON FUNCTION public.admin_restore_plan_feature(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_restore_plan_feature(uuid, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_restore_plan_feature(uuid, text) TO authenticated, service_role;
