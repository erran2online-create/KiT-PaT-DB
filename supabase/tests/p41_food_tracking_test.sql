-- P41 test: food_entries RLS (personal vs group-shared), record_food_entry/
-- list_food_entries/delete_food_entry, and anon lockout.
--
-- analyze-food (the edge function) is NOT SQL-testable and is NOT
-- exercised here -- this file only covers the SQL side: the table, its
-- RLS, and the three RPCs.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has this migration
-- (20260909040000_p41_food_tracking.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p41_food_tracking_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   a. A member can insert a personal entry (group_id NULL, via
--      record_food_entry) and read it back (via list_food_entries).
--   b. A second, unrelated member cannot read that personal entry.
--   c. A group-shared entry is readable by another member of that group
--      and not by a non-member.
--   d. A member cannot insert a row with another user's user_id (direct
--      table INSERT, bypassing record_food_entry).
--   e. delete_food_entry raises KITPAT_NOT_FOUND for a non-owner.
--   f. anon holds no EXECUTE on the three new functions and no privilege
--      (SELECT/INSERT/DELETE) on food_entries.

BEGIN;

DO $t$
DECLARE
  user_a uuid;
  user_b uuid;
  user_c uuid;
  group_id uuid;
  personal_entry_id uuid;
  shared_entry_id uuid;
  err text;
  row_rec record;
  visible_count integer;
  anon_priv boolean;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (name, phone, city) VALUES ('P41 User A', '9966000001', 'Chennai') RETURNING id INTO user_a;
  INSERT INTO public.users (name, phone, city) VALUES ('P41 User B', '9966000002', 'Chennai') RETURNING id INTO user_b;
  INSERT INTO public.users (name, phone, city) VALUES ('P41 User C', '9966000003', 'Chennai') RETURNING id INTO user_c;

  INSERT INTO public.groups (name, host_id, city) VALUES ('P41 Test Group ' || substr(gen_random_uuid()::text, 1, 8), user_a, 'Chennai') RETURNING id INTO group_id;
  INSERT INTO public.members (group_id, user_id, role) VALUES
    (group_id, user_a, 'host'),
    (group_id, user_b, 'member');
  -- user_c is deliberately NOT a member of group_id.

  --------------------------------------------------- a. personal entry round-trip
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_a::text, 'role', 'authenticated')::text, true);

  SELECT * INTO row_rec FROM public.record_food_entry('2 idli with sambar', '2 pieces');
  personal_entry_id := row_rec.id;
  IF personal_entry_id IS NULL OR row_rec.user_id <> user_a OR row_rec.group_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL: record_food_entry did not create a personal entry for user_a correctly: %', row_rec;
  END IF;
  IF row_rec.calories_kcal <> 0 OR row_rec.has_macros IS NOT false THEN
    RAISE EXCEPTION 'FAIL: a no-macros record_food_entry call returned calories_kcal=%, has_macros=%, expected 0/false (never a raw NULL)', row_rec.calories_kcal, row_rec.has_macros;
  END IF;

  SELECT count(*) INTO visible_count FROM public.list_food_entries(NULL, 50, 0) WHERE id = personal_entry_id;
  IF visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: user_a could not read back their own personal entry via list_food_entries';
  END IF;
  RAISE NOTICE 'PASS: a member can insert a personal entry and read it back, with macro fields coalesced to 0/has_macros=false rather than NULL';

  --------------------------------------------------- b. personal entry is private
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_b::text, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO visible_count FROM public.food_entries WHERE id = personal_entry_id;
  RESET ROLE;
  IF visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: user_b (a different, unrelated member) could see user_a''s personal entry (count=%), expected 0', visible_count;
  END IF;
  RAISE NOTICE 'PASS: a second member cannot read that personal entry';

  ----------------------------------------------- c. group-shared entry visibility
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_a::text, 'role', 'authenticated')::text, true);
  SELECT * INTO row_rec FROM public.record_food_entry('Group pizza night', '1 slice', group_id);
  shared_entry_id := row_rec.id;
  IF shared_entry_id IS NULL OR row_rec.group_id <> group_id THEN
    RAISE EXCEPTION 'FAIL: record_food_entry did not create a group-shared entry correctly: %', row_rec;
  END IF;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_b::text, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO visible_count FROM public.food_entries WHERE id = shared_entry_id;
  RESET ROLE;
  IF visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: user_b (a fellow group member) could not see the group-shared entry (count=%), expected 1', visible_count;
  END IF;

  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_c::text, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO visible_count FROM public.food_entries WHERE id = shared_entry_id;
  RESET ROLE;
  IF visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: user_c (not a member of the group) could see the group-shared entry (count=%), expected 0', visible_count;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_b::text, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO visible_count FROM public.list_food_entries(group_id, 50, 0) WHERE id = shared_entry_id;
  IF visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: list_food_entries(group_id) did not show the shared entry to a fellow group member';
  END IF;
  RAISE NOTICE 'PASS: a group-shared entry is readable by another member of that group and not by a non-member';

  --------------------------------------------- d. cannot insert with another user_id
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_a::text, 'role', 'authenticated')::text, true);
  BEGIN
    INSERT INTO public.food_entries (user_id, description) VALUES (user_b, 'forged entry');
    RAISE EXCEPTION 'FAIL: user_a could insert a food_entries row with user_b''s user_id';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  RESET ROLE;
  RAISE NOTICE 'PASS: a member cannot insert a row with another user''s user_id';

  --------------------------------------------------- e. delete_food_entry ownership
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_c::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.delete_food_entry(personal_entry_id);
    RAISE EXCEPTION 'FAIL: delete_food_entry succeeded for a non-owner';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_FOUND' THEN
      RAISE EXCEPTION 'FAIL: non-owner delete_food_entry raised "%", expected KITPAT_NOT_FOUND', err;
    END IF;
  END;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', user_a::text, 'role', 'authenticated')::text, true);
  PERFORM public.delete_food_entry(personal_entry_id);
  SELECT count(*) INTO visible_count FROM public.food_entries WHERE id = personal_entry_id;
  IF visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: delete_food_entry did not actually delete the entry for its owner';
  END IF;
  RAISE NOTICE 'PASS: delete_food_entry raises KITPAT_NOT_FOUND for a non-owner and succeeds for the owner';

  ------------------------------------------------------------------ f. anon lockout
  SELECT has_function_privilege('anon', 'public.record_food_entry(text,text,uuid,uuid,numeric,numeric,numeric,numeric,text,text,jsonb)', 'EXECUTE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on record_food_entry';
  END IF;
  SELECT has_function_privilege('anon', 'public.list_food_entries(uuid,int,int)', 'EXECUTE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on list_food_entries';
  END IF;
  SELECT has_function_privilege('anon', 'public.delete_food_entry(uuid)', 'EXECUTE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds EXECUTE on delete_food_entry';
  END IF;

  SELECT has_table_privilege('anon', 'public.food_entries', 'SELECT') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds SELECT on public.food_entries';
  END IF;
  SELECT has_table_privilege('anon', 'public.food_entries', 'INSERT') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds INSERT on public.food_entries';
  END IF;
  SELECT has_table_privilege('anon', 'public.food_entries', 'DELETE') INTO anon_priv;
  IF anon_priv IS NOT false THEN
    RAISE EXCEPTION 'FAIL: anon holds DELETE on public.food_entries';
  END IF;
  RAISE NOTICE 'PASS: anon holds no EXECUTE on the three new functions and no privilege on food_entries';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
  RAISE NOTICE 'NOTE: the analyze-food edge function itself was NOT tested here -- not SQL-testable.';
END;
$t$;

ROLLBACK;
