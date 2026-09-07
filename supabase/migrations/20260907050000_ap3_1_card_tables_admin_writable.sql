-- ---------------------------------------------------------------------------
-- AP3.1: make the AP3 card tables (festival_cards, promo_cards) writable
-- through the AP1 admin-write path.
--
-- Recreates admin_can_write(p_table) -- CREATE OR REPLACE, same signature,
-- LANGUAGE, volatility, security, search_path and grants as AP1's version
-- -- adding festival_cards/promo_cards to the allow-listed table set with
-- the same role rule as every content table except plans: org_admin and
-- owner may write, member may not.
--
-- The admin-write edge function's own allow-list (PK_COLUMN in
-- supabase/functions/admin-write/index.ts) is updated in the same PR to
-- match -- both card tables use a uuid `id` primary key, like every table
-- here except tambola_variants.
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
      'festival_themes', 'greeting_variants', 'tambola_variants',
      'festival_cards', 'promo_cards'
    ])
    AND (
      public.admin_role() = 'owner'
      OR (public.admin_role() = 'org_admin' AND p_table <> 'plans')
    );
$$;

COMMENT ON FUNCTION public.admin_can_write(text) IS
  'True if the caller is an active admin whose role permits writing p_table: owner writes every allow-listed table, org_admin writes all except plans, member never writes. The one place this rule is defined -- the admin-write edge function re-checks it as defense in depth.';

REVOKE ALL ON FUNCTION public.admin_can_write(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_can_write(text) TO authenticated, service_role;
