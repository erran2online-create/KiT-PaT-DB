-- ---------------------------------------------------------------------------
-- P37: gendered variant labels for badge_definitions.
--
-- 10 of the 50 badges have female-coded names (e.g. "Tambola Queen"). Adds
-- three nullable presentation columns so a user can later pick which label
-- they see (frontend reads the user's choice, falls back to name), and
-- renames those 10 rows' `name` to a neutral default.
--
-- Presentation labels only. Does NOT touch auto_rule logic, description,
-- emoji, category, is_host_assigned, or any of the other 40 badges.
-- ---------------------------------------------------------------------------

ALTER TABLE public.badge_definitions
  ADD COLUMN IF NOT EXISTS variant_neutral text,
  ADD COLUMN IF NOT EXISTS variant_male text,
  ADD COLUMN IF NOT EXISTS variant_female text;

COMMENT ON COLUMN public.badge_definitions.variant_neutral IS
  'Neutral-coded label for this badge. Also mirrored into name as the default displayed label.';
COMMENT ON COLUMN public.badge_definitions.variant_male IS
  'Male-coded label for this badge, where one exists. NULL if this badge has no gendered variant pair (neutral-only rename).';
COMMENT ON COLUMN public.badge_definitions.variant_female IS
  'Female-coded label for this badge, where one exists (also the badge''s original name pre-P37). NULL if this badge has no gendered variant pair (neutral-only rename).';

-- 7 badges with a full male/female/neutral triad -----------------------------
UPDATE public.badge_definitions
SET name = 'Tambola Champion', variant_neutral = 'Tambola Champion', variant_female = 'Tambola Queen', variant_male = 'Tambola King'
WHERE name = 'Tambola Queen';

UPDATE public.badge_definitions
SET name = 'The Hype', variant_neutral = 'The Hype', variant_female = 'Hype Woman', variant_male = 'Hype Man'
WHERE name = 'Hype Woman';

UPDATE public.badge_definitions
SET name = 'Bollywood Star', variant_neutral = 'Bollywood Star', variant_female = 'Bollywood Heroine', variant_male = 'Bollywood Hero'
WHERE name = 'Bollywood Heroine';

UPDATE public.badge_definitions
SET name = 'Nap Champion', variant_neutral = 'Nap Champion', variant_female = 'Nap Queen', variant_male = 'Nap King'
WHERE name = 'Nap Queen';

UPDATE public.badge_definitions
SET name = 'Gift Guru', variant_neutral = 'Gift Guru', variant_female = 'Gift Goddess', variant_male = 'Gift God'
WHERE name = 'Gift Goddess';

UPDATE public.badge_definitions
SET name = 'Comeback Star', variant_neutral = 'Comeback Star', variant_female = 'Comeback Queen', variant_male = 'Comeback King'
WHERE name = 'Comeback Queen';

UPDATE public.badge_definitions
SET name = 'Theme Master', variant_neutral = 'Theme Master', variant_female = 'Theme Queen', variant_male = 'Theme King'
WHERE name = 'Theme Queen';

-- 3 badges renamed neutral-only -- no male/female pair exists for these, so
-- variant_male and variant_female are left NULL.
UPDATE public.badge_definitions
SET name = 'The Oracle', variant_neutral = 'The Oracle'
WHERE name = 'Prediction Queen';

UPDATE public.badge_definitions
SET name = 'Ever-Present', variant_neutral = 'Ever-Present'
WHERE name = 'Consistent Queen';

UPDATE public.badge_definitions
SET name = 'Positivity Pro', variant_neutral = 'Positivity Pro'
WHERE name = 'Positivity Queen';
