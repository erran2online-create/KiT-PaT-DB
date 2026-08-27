-- P35 test: Bollywood tambola film pack, festival theme catalogue, Kitty
-- Special reveal-mode flag.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P35 migration
-- (20260828010000_p35_bollywood_films_festival_themes.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p35_bollywood_films_festival_themes_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. The bollywood tambola pack's content->'films' has length 358 for
--      every locale row, and pre-existing content keys (call_pack,
--      default_prizes, default_interval_seconds) survive the || merge.
--   2. festival_themes has exactly 20 seeded rows.
--   3. get_festival_options(10) returns navratri, karwa_chauth, diwali,
--      durga_puja, chhath (October -- several overlapping festivals),
--      ordered by sort_order.
--   4. The kitty_special pack's content has reveal_mode = 'festival_tiles'
--      and fallback = 'group_memory_photos' for every locale row, and its
--      pre-existing content keys also survive the merge.

BEGIN;

DO $t$
DECLARE
  rec record;
  films_len integer;
  festival_count integer;
  october_keys text[];
BEGIN
  ------------------------------------------------------- 1. bollywood films
  FOR rec IN
    SELECT locale, content FROM public.game_theme_packs
    WHERE game_key = 'tambola' AND theme_key = 'bollywood'
  LOOP
    IF rec.content->'films' IS NULL THEN
      RAISE EXCEPTION 'FAIL: bollywood pack (locale=%) has no films key', rec.locale;
    END IF;

    films_len := jsonb_array_length(rec.content->'films');
    IF films_len <> 358 THEN
      RAISE EXCEPTION 'FAIL: bollywood pack (locale=%) films length = %, expected 358', rec.locale, films_len;
    END IF;

    IF rec.content->>'call_pack' IS DISTINCT FROM 'bollywood' THEN
      RAISE EXCEPTION 'FAIL: bollywood pack (locale=%) lost call_pack after merge (got %)', rec.locale, rec.content->>'call_pack';
    END IF;
    IF rec.content->'default_prizes' IS NULL THEN
      RAISE EXCEPTION 'FAIL: bollywood pack (locale=%) lost default_prizes after merge', rec.locale;
    END IF;
    IF (rec.content->>'default_interval_seconds')::integer IS NULL THEN
      RAISE EXCEPTION 'FAIL: bollywood pack (locale=%) lost default_interval_seconds after merge', rec.locale;
    END IF;
  END LOOP;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: no game_theme_packs rows found for tambola/bollywood';
  END IF;
  RAISE NOTICE 'PASS: every bollywood locale row has content->films with length 358, and existing content keys survive the || merge';

  ------------------------------------------------------ 2. festival catalogue
  SELECT count(*) INTO festival_count FROM public.festival_themes;
  IF festival_count <> 20 THEN
    RAISE EXCEPTION 'FAIL: festival_themes has % rows, expected 20', festival_count;
  END IF;
  RAISE NOTICE 'PASS: festival_themes has exactly 20 seeded rows';

  --------------------------------------------------- 3. get_festival_options
  SELECT array_agg(key ORDER BY sort_order) INTO october_keys
  FROM public.get_festival_options(10);

  IF october_keys IS DISTINCT FROM ARRAY['navratri','karwa_chauth','diwali','durga_puja','chhath'] THEN
    RAISE EXCEPTION 'FAIL: get_festival_options(10) returned %, expected {navratri,karwa_chauth,diwali,durga_puja,chhath}', october_keys;
  END IF;
  RAISE NOTICE 'PASS: get_festival_options(10) returns navratri, karwa_chauth, diwali, durga_puja, chhath in sort_order';

  ------------------------------------------------------- 4. kitty_special
  FOR rec IN
    SELECT locale, content FROM public.game_theme_packs
    WHERE game_key = 'tambola' AND theme_key = 'kitty_special'
  LOOP
    IF rec.content->>'reveal_mode' IS DISTINCT FROM 'festival_tiles' THEN
      RAISE EXCEPTION 'FAIL: kitty_special pack (locale=%) reveal_mode = %, expected festival_tiles', rec.locale, rec.content->>'reveal_mode';
    END IF;
    IF rec.content->>'fallback' IS DISTINCT FROM 'group_memory_photos' THEN
      RAISE EXCEPTION 'FAIL: kitty_special pack (locale=%) fallback = %, expected group_memory_photos', rec.locale, rec.content->>'fallback';
    END IF;
    IF rec.content->>'call_pack' IS NULL THEN
      RAISE EXCEPTION 'FAIL: kitty_special pack (locale=%) lost pre-existing content after merge', rec.locale;
    END IF;
  END LOOP;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'FAIL: no game_theme_packs rows found for tambola/kitty_special';
  END IF;
  RAISE NOTICE 'PASS: every kitty_special locale row has reveal_mode=festival_tiles and fallback=group_memory_photos, with existing content keys preserved';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
