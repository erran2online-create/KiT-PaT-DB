-- ---------------------------------------------------------------------------
-- AP5: let the admin edit curated page copy, all legal documents, and
-- future marketing-website content, without code.
--
-- Does NOT replace the member app's 9-locale, 865-key i18n bundle (frontend
-- files) -- public.app_content is a small set of OVERRIDES/standalone
-- documents on top of it:
--   'app'     -- curated strings the frontend falls back to its own i18n
--                bundle for when a key is absent or unpublished here.
--   'legal'   -- privacy/terms/etc, seeded empty-but-present so the public
--                store-review URLs never 404 while the real text is
--                drafted separately and pasted in by the admin.
--   'website' -- future marketing-site copy, not yet consumed by anything.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. app_content
-- ---------------------------------------------------------------------------
CREATE TABLE public.app_content (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  key text NOT NULL,
  locale text NOT NULL DEFAULT 'en-IN',
  surface text NOT NULL,
  title text,
  body text,
  is_published boolean NOT NULL DEFAULT true,
  updated_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE (key, locale),
  CONSTRAINT app_content_surface_check CHECK (surface IN ('app', 'legal', 'website'))
);

COMMENT ON TABLE public.app_content IS
  'Admin-editable page copy: legal documents, curated app-string overrides (frontend falls back to its own i18n bundle when a key is absent/unpublished here -- never breaks the 9 shipped locales), and future marketing-website content. RLS: SELECT to anon and authenticated where is_published (legal pages must be readable signed-out for Play/App Store review); no client writes.';

ALTER TABLE public.app_content ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "anyone reads published app content" ON public.app_content;
CREATE POLICY "anyone reads published app content"
  ON public.app_content FOR SELECT TO anon, authenticated
  USING (is_published);

GRANT SELECT ON public.app_content TO anon, authenticated;
GRANT ALL ON public.app_content TO service_role;

CREATE TRIGGER app_content_updated_at
  BEFORE UPDATE ON public.app_content
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Seed: legal documents -- empty-but-present so public routes never
--    404. NOT real legal text: a short placeholder line only. The actual
--    document is drafted separately and pasted in by the admin.
-- ---------------------------------------------------------------------------
INSERT INTO public.app_content (key, locale, surface, title, body, is_published) VALUES
  ('privacy_policy',     'en-IN', 'legal', 'Privacy Policy',      'This document is being finalised. Please check back soon.', true),
  ('terms_of_service',   'en-IN', 'legal', 'Terms of Service',    'This document is being finalised. Please check back soon.', true),
  ('cookie_policy',      'en-IN', 'legal', 'Cookie Policy',       'This document is being finalised. Please check back soon.', true),
  ('about_us',           'en-IN', 'legal', 'About Us',            'This document is being finalised. Please check back soon.', true),
  ('support',            'en-IN', 'legal', 'Support',             'This document is being finalised. Please check back soon.', true),
  ('data_deletion',      'en-IN', 'legal', 'Data Deletion',       'This document is being finalised. Please check back soon.', true);

-- ---------------------------------------------------------------------------
-- 3. Seed: curated app strings (overrides -- absent/unpublished falls back
--    to the frontend's own i18n bundle).
-- ---------------------------------------------------------------------------
INSERT INTO public.app_content (key, locale, surface, title, body, is_published) VALUES
  ('home_hero_title',      'en-IN', 'app', NULL, 'Every celebration, sorted.', true),
  ('home_hero_subtitle',   'en-IN', 'app', NULL, 'Plan parties, run kitty groups, and keep the games going -- all in one place.', true),
  ('welcome_title',        'en-IN', 'app', NULL, 'Welcome to KiT-PaT!', true),
  ('welcome_subtitle',     'en-IN', 'app', NULL, 'Your group''s parties, kitties and memories, all in one home.', true),
  ('empty_groups',         'en-IN', 'app', NULL, 'No groups yet -- create one to get the party started.', true),
  ('empty_parties',        'en-IN', 'app', NULL, 'No parties planned yet. Tap below to host your first one.', true),
  ('empty_memories',       'en-IN', 'app', NULL, 'No memories saved yet -- they''ll show up here after your next event.', true),
  ('invite_share_message', 'en-IN', 'app', NULL, 'Join our group on KiT-PaT so we can plan parties and kitties together!', true);

-- ---------------------------------------------------------------------------
-- 4. Seed: website placeholders (not yet consumed by anything).
-- ---------------------------------------------------------------------------
INSERT INTO public.app_content (key, locale, surface, title, body, is_published) VALUES
  ('site_hero_headline',      'en-IN', 'website', NULL, 'The home for your kitty parties and group gatherings.', true),
  ('site_hero_subheadline',   'en-IN', 'website', NULL, 'Plan events, manage kitty contributions, and play group games together.', true),
  ('site_tagline',            'en-IN', 'website', NULL, 'Kitty parties, sorted.', true),
  ('site_cta_text',           'en-IN', 'website', NULL, 'Get the app', true),
  ('site_pricing_intro',      'en-IN', 'website', NULL, 'Simple plans for groups of every size.', true),
  ('site_install_android',    'en-IN', 'website', NULL, 'Get it on Google Play', true),
  ('site_install_ios',        'en-IN', 'website', NULL, 'Download on the App Store', true),
  ('site_footer_note',        'en-IN', 'website', NULL, 'KiT-PaT is a kitty-party and group-gathering app for friends and family.', true);

DO $$
DECLARE
  n integer;
BEGIN
  SELECT count(*) INTO n FROM public.app_content;
  IF n <> 22 THEN
    RAISE EXCEPTION 'AP5 seed produced % app_content rows, expected exactly 22 (6 legal + 8 app + 8 website)', n;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. get_app_content(p_surface, p_locale) -- published rows for a surface,
--    falling back to the 'en-IN' row when the requested locale has no row
--    for a key. One row per key: DISTINCT ON (key), preferring an exact
--    locale match over the en-IN fallback.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_app_content(p_surface text, p_locale text DEFAULT 'en-IN')
RETURNS TABLE (
  key text,
  locale text,
  title text,
  body text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT DISTINCT ON (c.key)
    c.key, c.locale, c.title, c.body
  FROM public.app_content c
  WHERE c.surface = p_surface
    AND c.is_published
    AND c.locale IN (p_locale, 'en-IN')
  ORDER BY c.key, (c.locale = p_locale) DESC;
$$;

COMMENT ON FUNCTION public.get_app_content(text, text) IS
  'Published app_content rows for p_surface, one per key: the p_locale row when published, else the en-IN row. Callable by anon and authenticated -- legal surface content must be readable signed-out for Play/App Store review.';

REVOKE ALL ON FUNCTION public.get_app_content(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_app_content(text, text) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. admin_can_write -- add app_content, same rule as every content table
--    except plans/coupons/coupon_targets: org_admin and owner may write,
--    member may not. Recreated in full (single source of truth for the
--    complete allow-listed table set); CREATE OR REPLACE keeps the same
--    signature and grants as every prior version.
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
      'festival_cards', 'promo_cards', 'coupons', 'coupon_targets',
      'app_content'
    ])
    AND (
      public.admin_role() = 'owner'
      OR (public.admin_role() = 'org_admin' AND p_table NOT IN ('plans', 'coupons', 'coupon_targets'))
    );
$$;

COMMENT ON FUNCTION public.admin_can_write(text) IS
  'True if the caller is an active admin whose role permits writing p_table: owner writes every allow-listed table, org_admin writes all except the owner-only set (plans, coupons, coupon_targets), member never writes. The one place this rule is defined -- the admin-write edge function re-checks it as defense in depth.';

REVOKE ALL ON FUNCTION public.admin_can_write(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_can_write(text) TO authenticated, service_role;
