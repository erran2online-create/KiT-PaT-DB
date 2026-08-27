-- P37 test: badge_definitions gendered variant labels.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P37 migration
-- (20260828030000_p37_badge_gendered_variant_labels.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p37_badge_gendered_variant_labels_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. Each of the 7 full-triad badges now has name = variant_neutral, and
--      variant_female / variant_male set to the expected gendered labels.
--   2. Each of the 3 neutral-only badges now has name = variant_neutral,
--      with variant_female and variant_male both NULL (no pair exists).
--   3. Exactly 10 rows carry a non-NULL variant_neutral; the other 40 rows
--      are completely untouched by this migration (all three variant
--      columns NULL).

BEGIN;

DO $t$
DECLARE
  b public.badge_definitions;
  total_count integer;
  variant_count integer;
  triad_count integer;
  neutral_only_count integer;
  untouched_with_stray_variant integer;
BEGIN
  ------------------------------------------------- 1. full-triad badges
  FOR b IN
    SELECT * FROM public.badge_definitions
    WHERE variant_female IS NOT NULL AND variant_male IS NOT NULL
  LOOP
    IF b.name <> b.variant_neutral THEN
      RAISE EXCEPTION 'FAIL: triad badge (variant_neutral=%) has name=%, expected name=variant_neutral', b.variant_neutral, b.name;
    END IF;
  END LOOP;

  PERFORM 1 FROM public.badge_definitions
  WHERE variant_neutral = 'Tambola Champion' AND variant_female = 'Tambola Queen' AND variant_male = 'Tambola King' AND name = 'Tambola Champion';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: Tambola Champion/Queen/King triad not found as expected'; END IF;

  PERFORM 1 FROM public.badge_definitions
  WHERE variant_neutral = 'The Hype' AND variant_female = 'Hype Woman' AND variant_male = 'Hype Man' AND name = 'The Hype';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: The Hype/Hype Woman/Hype Man triad not found as expected'; END IF;

  PERFORM 1 FROM public.badge_definitions
  WHERE variant_neutral = 'Bollywood Star' AND variant_female = 'Bollywood Heroine' AND variant_male = 'Bollywood Hero' AND name = 'Bollywood Star';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: Bollywood Star/Heroine/Hero triad not found as expected'; END IF;

  PERFORM 1 FROM public.badge_definitions
  WHERE variant_neutral = 'Nap Champion' AND variant_female = 'Nap Queen' AND variant_male = 'Nap King' AND name = 'Nap Champion';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: Nap Champion/Queen/King triad not found as expected'; END IF;

  PERFORM 1 FROM public.badge_definitions
  WHERE variant_neutral = 'Gift Guru' AND variant_female = 'Gift Goddess' AND variant_male = 'Gift God' AND name = 'Gift Guru';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: Gift Guru/Goddess/God triad not found as expected'; END IF;

  PERFORM 1 FROM public.badge_definitions
  WHERE variant_neutral = 'Comeback Star' AND variant_female = 'Comeback Queen' AND variant_male = 'Comeback King' AND name = 'Comeback Star';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: Comeback Star/Queen/King triad not found as expected'; END IF;

  PERFORM 1 FROM public.badge_definitions
  WHERE variant_neutral = 'Theme Master' AND variant_female = 'Theme Queen' AND variant_male = 'Theme King' AND name = 'Theme Master';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: Theme Master/Queen/King triad not found as expected'; END IF;

  RAISE NOTICE 'PASS: all 7 full-triad badges have name=variant_neutral and the expected variant_female/variant_male labels';

  ------------------------------------------------- 2. neutral-only badges
  PERFORM 1 FROM public.badge_definitions
  WHERE variant_neutral = 'The Oracle' AND name = 'The Oracle' AND variant_female IS NULL AND variant_male IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: The Oracle (ex Prediction Queen) not found with NULL variant_female/variant_male'; END IF;

  PERFORM 1 FROM public.badge_definitions
  WHERE variant_neutral = 'Ever-Present' AND name = 'Ever-Present' AND variant_female IS NULL AND variant_male IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: Ever-Present (ex Consistent Queen) not found with NULL variant_female/variant_male'; END IF;

  PERFORM 1 FROM public.badge_definitions
  WHERE variant_neutral = 'Positivity Pro' AND name = 'Positivity Pro' AND variant_female IS NULL AND variant_male IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL: Positivity Pro (ex Positivity Queen) not found with NULL variant_female/variant_male'; END IF;

  RAISE NOTICE 'PASS: all 3 neutral-only badges have name=variant_neutral, with variant_female and variant_male both NULL (no pair)';

  --------------------------------------------- 3. exactly 10 touched, 40 not
  SELECT count(*) INTO total_count FROM public.badge_definitions;
  IF total_count <> 50 THEN
    RAISE EXCEPTION 'FAIL: badge_definitions has % rows, expected 50 (this migration adds/removes no rows)', total_count;
  END IF;

  SELECT count(*) INTO variant_count FROM public.badge_definitions WHERE variant_neutral IS NOT NULL;
  IF variant_count <> 10 THEN
    RAISE EXCEPTION 'FAIL: % rows have a non-NULL variant_neutral, expected exactly 10', variant_count;
  END IF;

  SELECT count(*) INTO triad_count
  FROM public.badge_definitions
  WHERE variant_neutral IS NOT NULL AND variant_female IS NOT NULL AND variant_male IS NOT NULL;
  IF triad_count <> 7 THEN
    RAISE EXCEPTION 'FAIL: % rows have a full male/female/neutral triad, expected exactly 7', triad_count;
  END IF;

  SELECT count(*) INTO neutral_only_count
  FROM public.badge_definitions
  WHERE variant_neutral IS NOT NULL AND variant_female IS NULL AND variant_male IS NULL;
  IF neutral_only_count <> 3 THEN
    RAISE EXCEPTION 'FAIL: % rows have a neutral-only rename, expected exactly 3', neutral_only_count;
  END IF;

  SELECT count(*) INTO untouched_with_stray_variant
  FROM public.badge_definitions
  WHERE variant_neutral IS NULL AND (variant_female IS NOT NULL OR variant_male IS NOT NULL);
  IF untouched_with_stray_variant <> 0 THEN
    RAISE EXCEPTION 'FAIL: % untouched rows have a stray variant_female/variant_male with no variant_neutral', untouched_with_stray_variant;
  END IF;

  RAISE NOTICE 'PASS: exactly 10 of 50 rows carry variant labels (7 full triads + 3 neutral-only renames); the other 40 rows have all three variant columns NULL and are otherwise untouched';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
