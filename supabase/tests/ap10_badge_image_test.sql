-- AP10 test: badge_definitions image_* columns (nullable, no functions
-- created), a round-trip write, and that the member-facing badges read is
-- unchanged.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0-AP9 and this migration
-- (20260909020000_ap10_badge_image.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap10_badge_image_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. All five image_* columns exist on badge_definitions, are nullable,
--      and default to NULL.
--   b. All pre-existing badges still read normally with the new columns
--      NULL.
--   c. A badge row accepts image_cloudinary_public_id + image_url (plus
--      format/width/height) and reads back correctly.
--   d. The member-facing badges read (badges_public_read, unfiltered)
--      is unchanged -- still returns every badge row.
--   e. This migration creates zero functions, so there is nothing new
--      for anon to hold EXECUTE on -- asserted explicitly (a pg_proc
--      search for any AP10-introduced function name) rather than skipped.

BEGIN;

DO $t$
DECLARE
  col record;
  nullable_count integer := 0;
  default_notnull_count integer := 0;
  total_badge_count integer;
  null_image_count integer;
  member_visible_count integer;
  test_badge_id uuid;
  round_trip record;
  new_function_count integer;
BEGIN
  ------------------------------------------------------------- a. columns
  FOR col IN
    SELECT column_name, is_nullable, column_default
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'badge_definitions'
      AND column_name IN ('image_cloudinary_public_id', 'image_url', 'image_format', 'image_width', 'image_height')
  LOOP
    IF col.is_nullable <> 'YES' THEN
      RAISE EXCEPTION 'FAIL: badge_definitions.% is NOT NULL, expected nullable', col.column_name;
    END IF;
    IF col.column_default IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL: badge_definitions.% has default %, expected NULL default', col.column_name, col.column_default;
    END IF;
    nullable_count := nullable_count + 1;
  END LOOP;
  IF nullable_count <> 5 THEN
    RAISE EXCEPTION 'FAIL: found % of the 5 expected image_* columns on badge_definitions, expected 5', nullable_count;
  END IF;
  RAISE NOTICE 'PASS: all five image_* columns exist on badge_definitions, are nullable, and default to NULL';

  ------------------------------------------------ b. existing badges unaffected
  SELECT count(*) INTO total_badge_count FROM public.badge_definitions;
  IF total_badge_count = 0 THEN
    RAISE EXCEPTION 'FAIL: public.badge_definitions has no rows -- cannot meaningfully assert existing badges are unaffected';
  END IF;

  SELECT count(*) INTO null_image_count
  FROM public.badge_definitions
  WHERE image_cloudinary_public_id IS NULL
    AND image_url IS NULL
    AND image_format IS NULL
    AND image_width IS NULL
    AND image_height IS NULL;
  IF null_image_count <> total_badge_count THEN
    RAISE EXCEPTION 'FAIL: % of % existing badges do not have all image_* columns NULL', total_badge_count - null_image_count, total_badge_count;
  END IF;
  RAISE NOTICE 'PASS: all % existing badges read normally with every image_* column NULL', total_badge_count;

  --------------------------------------------------------- c. round-trip write
  SELECT id INTO test_badge_id FROM public.badge_definitions ORDER BY id LIMIT 1;

  UPDATE public.badge_definitions
  SET
    image_cloudinary_public_id = 'ap10_test/badge_sample',
    image_url = 'https://res.cloudinary.com/kitpat/image/upload/v1/ap10_test/badge_sample.png',
    image_format = 'png',
    image_width = 512,
    image_height = 512
  WHERE id = test_badge_id;

  SELECT image_cloudinary_public_id, image_url, image_format, image_width, image_height
    INTO round_trip
    FROM public.badge_definitions WHERE id = test_badge_id;

  IF round_trip.image_cloudinary_public_id <> 'ap10_test/badge_sample'
     OR round_trip.image_url <> 'https://res.cloudinary.com/kitpat/image/upload/v1/ap10_test/badge_sample.png'
     OR round_trip.image_format <> 'png'
     OR round_trip.image_width <> 512
     OR round_trip.image_height <> 512 THEN
    RAISE EXCEPTION 'FAIL: badge image round-trip did not read back correctly: %', round_trip;
  END IF;
  RAISE NOTICE 'PASS: a badge row accepts image_cloudinary_public_id/image_url (+format/width/height) and reads back correctly';

  --------------------------------------------- d. member-facing read unchanged
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO member_visible_count FROM public.badge_definitions;
  RESET ROLE;
  IF member_visible_count <> total_badge_count THEN
    RAISE EXCEPTION 'FAIL: member-facing badge read returned % rows, expected all % (badges_public_read should be unchanged)', member_visible_count, total_badge_count;
  END IF;
  RAISE NOTICE 'PASS: the member-facing badges read (badges_public_read) is unchanged';

  --------------------------------------------- e. no new function, nothing for anon
  -- This migration adds columns only -- no CREATE FUNCTION statement at
  -- all. Asserted explicitly (rather than skipped) by confirming no
  -- function plausibly introduced by it exists in schema public.
  SELECT count(*) INTO new_function_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND (p.proname ILIKE '%badge_image%' OR p.proname ILIKE '%ap10%');
  IF new_function_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: found % unexpected function(s) matching an AP10-shaped name -- this migration was expected to create none', new_function_count;
  END IF;
  RAISE NOTICE 'PASS: this migration creates zero functions, so there is nothing new for anon to hold EXECUTE on';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
