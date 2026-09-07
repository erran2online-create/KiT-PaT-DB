-- ---------------------------------------------------------------------------
-- AP3: the card CONTENT layer the admin edits without code. 7 fixed
-- frontend templates ('celebration_banner', 'glow_tile', 'cinematic',
-- 'confetti_pop', 'countdown_deluxe', 'gift_reveal', 'diya_row'); the
-- database holds the content and which template each card uses.
--
-- 1. public.festival_cards -- one card per (festival, template). Seeded
--    with 5 of the 7 templates (celebration_banner, glow_tile, cinematic,
--    confetti_pop, countdown_deluxe) for all 20 existing festival_themes
--    rows = 100 rows. gift_reveal and diya_row are left for admin-created
--    cards, not seeded here.
-- 2. public.promo_cards -- admin-created, not tied to a festival, targeted
--    by placement and optionally scheduled via starts_at/ends_at.
-- 3. public.get_active_cards(p_placement) -- currently-active promo_cards
--    for a placement, mirroring the promo_cards RLS window exactly.
--
-- RLS on both tables: SELECT to authenticated only (further restricted by
-- an is_active/schedule window on promo_cards); no client writes. Content
-- writes go through the AP1 admin-write edge function once festival_cards
-- and promo_cards are added to its table allow-list -- NOT done in this
-- migration (the allow-list is in supabase/functions/admin-write/index.ts
-- and public.admin_can_write(), both code/data this migration deliberately
-- does not touch; see the PR body for the follow-up).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. festival_cards
-- ---------------------------------------------------------------------------
CREATE TABLE public.festival_cards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  festival_key text NOT NULL REFERENCES public.festival_themes(key) ON DELETE CASCADE,
  template text NOT NULL,
  title text NOT NULL,
  subtitle text,
  cta_text text,
  emoji text,
  color_from text,
  color_to text,
  accent text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  CONSTRAINT festival_cards_template_check CHECK (template IN (
    'celebration_banner', 'glow_tile', 'cinematic', 'confetti_pop',
    'countdown_deluxe', 'gift_reveal', 'diya_row'
  ))
);

COMMENT ON TABLE public.festival_cards IS
  'Card CONTENT for a fixed frontend template, one row per (festival_key, template). RLS: SELECT to authenticated where is_active; no client writes -- add to the AP1 admin-write allow-list to let admins edit these without code.';

ALTER TABLE public.festival_cards ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated read active festival cards" ON public.festival_cards;
CREATE POLICY "authenticated read active festival cards"
  ON public.festival_cards FOR SELECT TO authenticated
  USING (is_active);

GRANT SELECT ON public.festival_cards TO authenticated;
GRANT ALL ON public.festival_cards TO service_role;

CREATE TRIGGER festival_cards_updated_at
  BEFORE UPDATE ON public.festival_cards
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ---------------------------------------------------------------------------
-- Seed: 5 templates x 20 festivals = 100 rows. Copy is specific to each
-- festival (drawn from its own name/art_cues); colors suit its mood.
-- cta_text varies by template so the seeded set isn't visually monotone.
-- ---------------------------------------------------------------------------
WITH seed_content (festival_key, title, subtitle, color_from, color_to, accent) AS (
  VALUES
    ('makar_sankranti',    'Sankranti Kite Mela',      'Kites, til-gud & golden sunshine',        '#fdb813', '#ff7a00', '#ffe066'),
    ('republic_day',       'Republic Day Salute',      'Tricolour pride, parade energy',          '#ff9933', '#138808', '#0a3d91'),
    ('holi',               'Holi Hai!',                'Colour splashes & gujiya sweetness',      '#ff3cac', '#784ba0', '#ffe156'),
    ('eid',                'Eid Mubarak Moments',      'Crescent moons & sweet sewaiyaan',        '#0f9b8e', '#0b5345', '#d4af37'),
    ('baisakhi',           'Baisakhi Bhangra Beat',    'Golden wheat & dhol drumbeats',           '#f2c94c', '#27ae60', '#e67e22'),
    ('raksha_bandhan',     'Rakhi Ka Tyohar',          'Rakhi threads & thali sweetness',         '#ff6f91', '#c9184a', '#ffd166'),
    ('independence_day',   'Azadi Ka Jashn',           'Tricolour skies, kites soaring high',     '#ff9933', '#138808', '#0a3d91'),
    ('janmashtami',        'Janmashtami Dahi Handi',   'Matki, flute & peacock grace',            '#3f51b5', '#6a1b9a', '#ffd700'),
    ('ganesh_chaturthi',   'Ganpati Bappa Morya',      'Modaks, dhol beats & blessings',          '#ff8a00', '#d7263d', '#ffd23f'),
    ('navratri',           'Navratri Garba Nights',    'Dandiya sticks & nine vibrant colours',   '#ff512f', '#dd2476', '#f9d423'),
    ('karwa_chauth',       'Karwa Chauth Chaand',      'Chhalni, moonlight & mehendi glow',       '#b71c1c', '#4a0404', '#ffc1cc'),
    ('diwali',             'Diwali Dhamaka',           'Diyas, rangoli & sweet celebrations',     '#b8860b', '#8b0000', '#ffd700'),
    ('christmas',          'Christmas Cheer',          'Twinkling trees & jingle bells',          '#c0392b', '#145a32', '#f1c40f'),
    ('new_year',           'New Year Countdown',       'Fireworks, confetti & midnight magic',    '#1a2980', '#26d0ce', '#f5f5f5'),
    ('durga_puja',         'Durga Puja Pandal Hop',    'Dhak beats & red-white saree grace',      '#c0392b', '#7b241c', '#f4d03f'),
    ('onam',               'Onam Sadya Special',       'Pookalam blooms & boat race thrills',     '#1e8449', '#145a32', '#f4d03f'),
    ('bihu',               'Bihu Dance Delight',       'Gamosa colours & paddy field joy',        '#f2c14e', '#2e8b57', '#b22222'),
    ('chhath',             'Chhath Puja Aasha',        'Sunrise, river & thekua warmth',          '#ff7e5f', '#feb47b', '#ffdd00'),
    ('lohri',              'Lohri Bonfire Beats',      'Bonfire crackle & rewri sweetness',       '#f12711', '#f5af19', '#8b0000'),
    ('gudi_padwa',         'Gudi Padwa Naya Saal',     'Gudi flags & marigold freshness',         '#f7b733', '#4caf50', '#ff5722')
),
template_defs (template, cta_text, sort_order) AS (
  VALUES
    ('celebration_banner', 'See offer',  0),
    ('glow_tile',          'Play now',   1),
    ('cinematic',          'Explore',    2),
    ('confetti_pop',       'Join in',    3),
    ('countdown_deluxe',   'Claim now',  4)
)
INSERT INTO public.festival_cards (festival_key, template, title, subtitle, cta_text, emoji, color_from, color_to, accent, sort_order)
SELECT ft.key, td.template, sc.title, sc.subtitle, td.cta_text, ft.emoji, sc.color_from, sc.color_to, sc.accent, td.sort_order
FROM public.festival_themes ft
JOIN seed_content sc ON sc.festival_key = ft.key
CROSS JOIN template_defs td;

DO $$
DECLARE
  n integer;
BEGIN
  SELECT count(*) INTO n FROM public.festival_cards;
  IF n <> 100 THEN
    RAISE EXCEPTION 'AP3 seed produced % festival_cards rows, expected exactly 100 (20 festivals x 5 templates) -- festival_themes may not have the 20 keys this migration assumed', n;
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. promo_cards -- admin-created, not tied to a festival, self-expiring.
-- ---------------------------------------------------------------------------
CREATE TABLE public.promo_cards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template text NOT NULL,
  title text NOT NULL,
  subtitle text,
  cta_text text,
  cta_url text,
  emoji text,
  color_from text,
  color_to text,
  accent text,
  placement text NOT NULL DEFAULT 'home' CHECK (placement IN ('home', 'groups', 'games', 'kitty', 'memories')),
  starts_at timestamptz,
  ends_at timestamptz,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  CONSTRAINT promo_cards_template_check CHECK (template IN (
    'celebration_banner', 'glow_tile', 'cinematic', 'confetti_pop',
    'countdown_deluxe', 'gift_reveal', 'diya_row'
  ))
);

COMMENT ON TABLE public.promo_cards IS
  'Admin-created cards, not tied to a festival, targeted by placement and optionally scheduled via starts_at/ends_at. RLS: SELECT to authenticated where is_active and currently within its schedule window, so a card appears and expires on its own without an admin edit. No client writes. get_active_cards(p_placement) is the intended read path -- add to the AP1 admin-write allow-list to let admins edit these without code.';

ALTER TABLE public.promo_cards ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated read active promo cards" ON public.promo_cards;
CREATE POLICY "authenticated read active promo cards"
  ON public.promo_cards FOR SELECT TO authenticated
  USING (
    is_active
    AND (starts_at IS NULL OR starts_at <= now())
    AND (ends_at IS NULL OR ends_at >= now())
  );

GRANT SELECT ON public.promo_cards TO authenticated;
GRANT ALL ON public.promo_cards TO service_role;

CREATE TRIGGER promo_cards_updated_at
  BEFORE UPDATE ON public.promo_cards
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ---------------------------------------------------------------------------
-- 3. get_active_cards(p_placement) -- mirrors the promo_cards RLS window
--    exactly, so a direct SELECT and this RPC never disagree on what's
--    "active".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_active_cards(p_placement text DEFAULT 'home')
RETURNS SETOF public.promo_cards
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT *
  FROM public.promo_cards
  WHERE placement = p_placement
    AND is_active
    AND (starts_at IS NULL OR starts_at <= now())
    AND (ends_at IS NULL OR ends_at >= now())
  ORDER BY created_at DESC;
$$;

COMMENT ON FUNCTION public.get_active_cards(text) IS
  'Currently-active promo_cards for p_placement (default ''home''): is_active and within its starts_at/ends_at schedule window, ordered by created_at desc.';

REVOKE ALL ON FUNCTION public.get_active_cards(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_active_cards(text) TO authenticated, service_role;
