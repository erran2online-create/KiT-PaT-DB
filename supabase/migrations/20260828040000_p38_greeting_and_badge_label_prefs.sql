-- ---------------------------------------------------------------------------
-- P38: per-user greeting preference + badge label gender preference, and a
-- rotating "collective noun" catalogue for the daily greeting.
--
-- 1. users.greeting_pref / users.badge_label_pref -- nullable preference
--    columns. No RPC needed to set them: the existing users_update_own RLS
--    policy (id = auth.uid()) is row-level and column-agnostic, so it
--    already covers writes to these new columns, same as P25's
--    groups.traditions.
--
-- 2. greeting_variants -- admin-editable catalogue (readable by
--    authenticated, writable only by service_role), seeded with 16 phrases.
--
-- 3. get_daily_greeting() -- returns the caller's pinned greeting_pref if
--    set, else a deterministic day-of-year pick from active
--    greeting_variants (same word for everyone that day).
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. users preference columns
-- ---------------------------------------------------------------------------
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS greeting_pref text,
  ADD COLUMN IF NOT EXISTS badge_label_pref text
    CHECK (badge_label_pref IN ('neutral', 'female', 'male'));

COMMENT ON COLUMN public.users.greeting_pref IS
  'Pinned collective-noun greeting phrase (must match an active greeting_variants.phrase to have effect). NULL = rotate daily via get_daily_greeting().';
COMMENT ON COLUMN public.users.badge_label_pref IS
  'Which badge_definitions variant column (variant_neutral / variant_female / variant_male) the frontend should display for this user. NULL = frontend falls back to badge_definitions.name.';

-- RLS note: users_update_own (id = auth.uid()) is row-level and
-- column-agnostic, so it already covers these two new columns without
-- change -- a user can read/update their own greeting_pref and
-- badge_label_pref exactly like any other own-row column.

-- ---------------------------------------------------------------------------
-- 2. greeting_variants catalogue
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.greeting_variants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phrase text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0
);

COMMENT ON TABLE public.greeting_variants IS
  'Rotating collective-noun phrases for the daily greeting (get_daily_greeting). Admin-editable later via an edge function; RLS here only grants read to authenticated.';

INSERT INTO public.greeting_variants (phrase, sort_order) VALUES
  ('your gang', 0),
  ('your crew', 1),
  ('your circle', 2),
  ('your people', 3),
  ('your squad', 4),
  ('your tribe', 5),
  ('your besties', 6),
  ('your clan', 7),
  ('your gharana', 8),
  ('your toli', 9),
  ('your adda', 10),
  ('your chai club', 11),
  ('your dhamaka crew', 12),
  ('your masti gang', 13),
  ('your dream team', 14),
  ('your group', 15);

ALTER TABLE public.greeting_variants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated read greeting variants" ON public.greeting_variants;
CREATE POLICY "authenticated read greeting variants"
  ON public.greeting_variants FOR SELECT TO authenticated
  USING (is_active = true);

-- No INSERT/UPDATE/DELETE policy for authenticated: only service_role (or a
-- future admin edge function running as service_role) can write.
GRANT SELECT ON public.greeting_variants TO authenticated;
GRANT ALL ON public.greeting_variants TO service_role;

-- ---------------------------------------------------------------------------
-- 3. get_daily_greeting() -- pinned pref, else deterministic day-of-year pick
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_daily_greeting()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  pinned text;
  variants text[];
  day_idx integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;

  SELECT greeting_pref INTO pinned FROM public.users WHERE id = auth.uid();
  IF pinned IS NOT NULL THEN
    RETURN pinned;
  END IF;

  SELECT array_agg(phrase ORDER BY sort_order, id) INTO variants
  FROM public.greeting_variants
  WHERE is_active = true;

  IF variants IS NULL OR array_length(variants, 1) = 0 THEN
    RAISE EXCEPTION 'KITPAT_NO_GREETING_VARIANTS';
  END IF;

  -- Same word for everyone on a given day: index by day-of-year (IST),
  -- wrapping around the active phrase count.
  day_idx := (extract(doy FROM (now() AT TIME ZONE 'Asia/Kolkata'))::integer - 1) % array_length(variants, 1);

  RETURN variants[day_idx + 1];
END;
$$;

COMMENT ON FUNCTION public.get_daily_greeting() IS
  'Returns the caller''s pinned users.greeting_pref if set, else a deterministic day-of-year pick from active greeting_variants (same phrase for every unpinned user on a given day, IST). Errors: KITPAT_UNAUTHENTICATED / KITPAT_NO_GREETING_VARIANTS.';

REVOKE ALL ON FUNCTION public.get_daily_greeting() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_daily_greeting() TO authenticated, service_role;
