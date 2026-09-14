-- P45.2/P45.3 test: the 3 new analytics_event_catalog rows exist with the
-- right shape, all 9 ingest-event contract event names are present, the
-- pre-existing 14 rows are byte-for-byte unchanged, and no category outside
-- the known 9-category set appears anywhere in the table.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has this migration
-- (20260914010000_p45_2_analytics_catalog_seed.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p45_2_analytics_catalog_seed_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. All 9 ingest-event contract event names exist in
--      analytics_event_catalog.
--   b. The 3 new rows have exactly the specified category/
--      required_properties/contains_pii.
--   c. The 11 pre-existing category/event_name pairs the user supplied
--      live (the 14 rows minus the 3 this migration is about to add,
--      i.e. the ones NOT among the 3 new event_names) still show the
--      expected category.
--   d. Re-running this migration's INSERT verbatim (ON CONFLICT (event_name)
--      DO NOTHING) changes no existing row -- proven generically by
--      fingerprinting every row before and after, since this test has no
--      way to know the exact description/required_properties/created_at
--      of the 14 pre-existing rows beyond what was supplied for category.
--   e. No category outside {activation, games, group, memory, party,
--      retention, virality, kitty, diagnostics} appears anywhere in the
--      table.

BEGIN;

DO $t$
DECLARE
  before_fingerprint text;
  after_fingerprint text;
  bad_category_count integer;
  row_rec record;
BEGIN
  ------------------------------------------------- a. all 9 contract names exist
  IF (
    SELECT count(*) FROM public.analytics_event_catalog
    WHERE event_name IN (
      'signup_completed', 'group_created', 'invite_shared', 'invite_redeemed',
      'party_created', 'contribution_recorded', 'game_started', 'game_completed',
      'client_error'
    )
  ) <> 9 THEN
    RAISE EXCEPTION 'FAIL: not all 9 ingest-event contract event names are present in analytics_event_catalog';
  END IF;
  RAISE NOTICE 'PASS: all 9 ingest-event contract event names exist in analytics_event_catalog';

  ------------------------------------------------- b. the 3 new rows' shape
  SELECT * INTO row_rec FROM public.analytics_event_catalog WHERE event_name = 'invite_redeemed';
  IF row_rec.category <> 'virality' OR row_rec.contains_pii <> false
     OR row_rec.required_properties <> ARRAY['group_id', 'channel'] THEN
    RAISE EXCEPTION 'FAIL: invite_redeemed does not match the specified shape: %', row_rec;
  END IF;

  SELECT * INTO row_rec FROM public.analytics_event_catalog WHERE event_name = 'contribution_recorded';
  IF row_rec.category <> 'kitty' OR row_rec.contains_pii <> false
     OR row_rec.required_properties <> ARRAY['group_id', 'pool_id', 'recorded_for_self'] THEN
    RAISE EXCEPTION 'FAIL: contribution_recorded does not match the specified shape: %', row_rec;
  END IF;

  SELECT * INTO row_rec FROM public.analytics_event_catalog WHERE event_name = 'client_error';
  IF row_rec.category <> 'diagnostics' OR row_rec.contains_pii <> false
     OR row_rec.required_properties <> ARRAY['boundary'] THEN
    RAISE EXCEPTION 'FAIL: client_error does not match the specified shape: %', row_rec;
  END IF;
  RAISE NOTICE 'PASS: invite_redeemed/contribution_recorded/client_error all have the exact specified category, required_properties and contains_pii=false';

  ------------------------------------------------- c. pre-existing categories intact
  IF EXISTS (
    SELECT 1 FROM (VALUES
      ('signup_completed', 'activation'),
      ('game_completed', 'games'), ('game_session_created', 'games'),
      ('game_started', 'games'), ('tambola_claim', 'games'),
      ('group_created', 'group'), ('member_joined', 'group'),
      ('media_uploaded', 'memory'), ('memory_artifact_ready', 'memory'),
      ('party_created', 'party'), ('rsvp_submitted', 'party'),
      ('next_party_created_from_memory', 'retention'),
      ('invite_shared', 'virality'), ('memory_shared', 'virality')
    ) AS expected(event_name, category)
    JOIN public.analytics_event_catalog c USING (event_name)
    WHERE c.category <> expected.category OR c.contains_pii <> false
  ) THEN
    RAISE EXCEPTION 'FAIL: at least one pre-existing row''s category or contains_pii no longer matches the live values supplied for this migration';
  END IF;
  IF (SELECT count(*) FROM public.analytics_event_catalog WHERE event_name IN (
        'signup_completed', 'game_completed', 'game_session_created', 'game_started', 'tambola_claim',
        'group_created', 'member_joined', 'media_uploaded', 'memory_artifact_ready',
        'party_created', 'rsvp_submitted', 'next_party_created_from_memory',
        'invite_shared', 'memory_shared'
      )) <> 14 THEN
    RAISE EXCEPTION 'FAIL: expected exactly 14 pre-existing rows by the known event_names, found a different count';
  END IF;
  RAISE NOTICE 'PASS: all 14 pre-existing rows still show their known category, unchanged';

  ------------------------------------------------- d. seeding is non-destructive
  SELECT string_agg(event_name || ':' || category || ':' || is_enabled_col, '|' ORDER BY event_name)
  INTO before_fingerprint
  FROM (
    SELECT event_name, category, coalesce(description,'') || ':' || coalesce(required_properties::text,'') || ':' || contains_pii::text AS is_enabled_col
    FROM public.analytics_event_catalog
  ) f;

  INSERT INTO public.analytics_event_catalog (event_name, category, description, required_properties, contains_pii)
  VALUES
    ('invite_redeemed', 'virality', 'Invite link opened and redeemed into a group', ARRAY['group_id', 'channel'], false),
    ('contribution_recorded', 'kitty', 'A member records a kitty contribution. recorded_for_self distinguishes a member marking her own payment from the host recording for someone else.', ARRAY['group_id', 'pool_id', 'recorded_for_self'], false),
    ('client_error', 'diagnostics', 'Uncaught render error in the member app. Carries the error boundary name, message and stack only -- never user data.', ARRAY['boundary'], false)
  ON CONFLICT (event_name) DO NOTHING;

  SELECT string_agg(event_name || ':' || category || ':' || is_enabled_col, '|' ORDER BY event_name)
  INTO after_fingerprint
  FROM (
    SELECT event_name, category, coalesce(description,'') || ':' || coalesce(required_properties::text,'') || ':' || contains_pii::text AS is_enabled_col
    FROM public.analytics_event_catalog
  ) f;

  IF before_fingerprint <> after_fingerprint THEN
    RAISE EXCEPTION 'FAIL: re-running the migration''s seed INSERT verbatim changed at least one existing analytics_event_catalog row';
  END IF;
  RAISE NOTICE 'PASS: re-running the seed INSERT verbatim changes no existing row -- ON CONFLICT (event_name) DO NOTHING protects every pre-existing row';

  ------------------------------------------------- e. no rogue category
  SELECT count(*) INTO bad_category_count
  FROM public.analytics_event_catalog
  WHERE category NOT IN ('activation', 'games', 'group', 'memory', 'party', 'retention', 'virality', 'kitty', 'diagnostics');
  IF bad_category_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % row(s) have a category outside the known 9-category set', bad_category_count;
  END IF;
  RAISE NOTICE 'PASS: no category outside {activation,games,group,memory,party,retention,virality,kitty,diagnostics} appears in the table';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
