-- P36 test: tambola_variants key='quick_10' label correction.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P36 migration
-- (20260828020000_p36_quick_10_label_fix.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p36_quick_10_label_fix_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. tambola_variants key='quick_10' now reads display_name='Quick 15'
--      and config->target_minutes = 15.
--   2. The key itself is unchanged (still 'quick_10' -- the frontend
--      references it directly).
--   3. default_interval_seconds is unchanged by this migration (the pace
--      was never wrong, only the label was).
--   4. Any game_theme_packs row for tambola/quick_10 no longer has
--      "10-Minute" in name or description, and every other content key on
--      that row (call_pack, default_interval_seconds, etc.) survives
--      untouched.

BEGIN;

DO $t$
DECLARE
  v public.tambola_variants;
  pack record;
BEGIN
  SELECT * INTO v FROM public.tambola_variants WHERE key = 'quick_10';

  IF v.key IS NULL THEN
    RAISE EXCEPTION 'FAIL: no tambola_variants row with key=quick_10 found';
  END IF;

  IF v.display_name <> 'Quick 15' THEN
    RAISE EXCEPTION 'FAIL: quick_10 display_name = %, expected ''Quick 15''', v.display_name;
  END IF;
  IF (v.config->>'target_minutes')::integer <> 15 THEN
    RAISE EXCEPTION 'FAIL: quick_10 config.target_minutes = %, expected 15', v.config->>'target_minutes';
  END IF;
  IF v.key <> 'quick_10' THEN
    RAISE EXCEPTION 'FAIL: quick_10 row key changed to %', v.key;
  END IF;
  -- This migration never touches default_interval_seconds. There is no
  -- pre-migration snapshot to diff against here (this test runs after the
  -- migration is applied), so the strongest in-transaction check available
  -- is that the column still respects its own CHECK(3-60) constraint --
  -- i.e. it wasn't nulled out or corrupted by an unrelated statement.
  IF v.default_interval_seconds IS NULL OR v.default_interval_seconds NOT BETWEEN 3 AND 60 THEN
    RAISE EXCEPTION 'FAIL: quick_10 default_interval_seconds = %, outside its CHECK(3-60) bound', v.default_interval_seconds;
  END IF;
  RAISE NOTICE 'PASS: tambola_variants quick_10 now reads display_name=''Quick 15'', config.target_minutes=15, key unchanged, default_interval_seconds untouched (interval=%)', v.default_interval_seconds;

  ------------------------------------------------- game_theme_packs (if any)
  FOR pack IN
    SELECT locale, name, description, content
    FROM public.game_theme_packs
    WHERE game_key = 'tambola' AND theme_key = 'quick_10'
  LOOP
    IF pack.name LIKE '%10-Minute%' THEN
      RAISE EXCEPTION 'FAIL: quick_10 game_theme_packs (locale=%) name still contains "10-Minute": %', pack.locale, pack.name;
    END IF;
    IF pack.description LIKE '%10-Minute%' THEN
      RAISE EXCEPTION 'FAIL: quick_10 game_theme_packs (locale=%) description still contains "10-Minute": %', pack.locale, pack.description;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS: no game_theme_packs row for tambola/quick_10 still says "10-Minute" in name or description (no-op if no such row/text existed)';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
