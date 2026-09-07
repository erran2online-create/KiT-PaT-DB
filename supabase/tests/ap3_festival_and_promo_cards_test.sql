-- AP3 test: festival_cards seed shape, the template CHECK constraint,
-- get_active_cards' schedule/placement filtering, and that both new tables
-- reject direct client writes.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0 and this migration
-- (20260907040000_ap3_festival_and_promo_cards.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap3_festival_and_promo_cards_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. festival_cards has exactly 100 seeded rows: 5 per festival across
--      all 20 festival_themes keys, and every seeded template value is one
--      of the 7 allow-listed templates.
--   2. The template CHECK constraint rejects an out-of-list value on both
--      festival_cards and promo_cards.
--   3. get_active_cards excludes a not-yet-started card (future starts_at)
--      and an expired card (past ends_at), includes a currently-active
--      one, and filters by placement.
--   4. Direct client (authenticated, anon) INSERT into festival_cards and
--      promo_cards each fail.

BEGIN;

DO $t$
DECLARE
  festival_count integer;
  card_count integer;
  per_festival_bad integer;
  bad_template_count integer;
  write_blocked boolean;
  future_id uuid;
  expired_id uuid;
  active_id uuid;
  other_placement_id uuid;
  found_future boolean;
  found_expired boolean;
  found_active boolean;
  found_other_placement boolean;
  any_festival_key text;
BEGIN
  ---------------------------------------------------------- 1. seed shape
  SELECT count(*) INTO festival_count FROM public.festival_themes;
  IF festival_count <> 20 THEN
    RAISE EXCEPTION 'FAIL: public.festival_themes has % rows, expected the 20 this migration assumed -- the seed-count assertions below are not meaningful against a different set', festival_count;
  END IF;

  SELECT count(*) INTO card_count FROM public.festival_cards;
  IF card_count <> 100 THEN
    RAISE EXCEPTION 'FAIL: public.festival_cards has % rows, expected exactly 100 (20 festivals x 5 templates)', card_count;
  END IF;

  SELECT count(*) INTO per_festival_bad FROM (
    SELECT festival_key, count(*) AS n
    FROM public.festival_cards
    GROUP BY festival_key
    HAVING count(*) <> 5
  ) bad;
  IF per_festival_bad <> 0 THEN
    RAISE EXCEPTION 'FAIL: % festival(s) do not have exactly 5 seeded cards', per_festival_bad;
  END IF;

  SELECT count(DISTINCT festival_key) INTO festival_count FROM public.festival_cards;
  IF festival_count <> 20 THEN
    RAISE EXCEPTION 'FAIL: seeded festival_cards cover % distinct festivals, expected 20', festival_count;
  END IF;

  SELECT count(*) INTO bad_template_count FROM public.festival_cards
  WHERE template NOT IN ('celebration_banner', 'glow_tile', 'cinematic', 'confetti_pop', 'countdown_deluxe', 'gift_reveal', 'diya_row');
  IF bad_template_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % seeded festival_cards rows have a template outside the allow-listed set', bad_template_count;
  END IF;
  RAISE NOTICE 'PASS: festival_cards has exactly 100 seeded rows, 5 per festival across 20 festivals, all templates allow-listed';

  ---------------------------------------------------------- 2. CHECK constraint
  SELECT key INTO any_festival_key FROM public.festival_themes LIMIT 1;

  BEGIN
    INSERT INTO public.festival_cards (festival_key, template, title)
    VALUES (any_festival_key, 'not_a_real_template', 'Bad Card');
    RAISE EXCEPTION 'FAIL: festival_cards accepted an out-of-list template value';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.promo_cards (template, title) VALUES ('not_a_real_template', 'Bad Promo');
    RAISE EXCEPTION 'FAIL: promo_cards accepted an out-of-list template value';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;
  RAISE NOTICE 'PASS: the template CHECK constraint rejects an out-of-list value on both tables';

  ---------------------------------------------------------- 3. get_active_cards window
  INSERT INTO public.promo_cards (template, title, placement, starts_at, ends_at, is_active)
  VALUES ('glow_tile', 'AP3 Future Card', 'home', now() + interval '1 day', NULL, true)
  RETURNING id INTO future_id;

  INSERT INTO public.promo_cards (template, title, placement, starts_at, ends_at, is_active)
  VALUES ('glow_tile', 'AP3 Expired Card', 'home', NULL, now() - interval '1 day', true)
  RETURNING id INTO expired_id;

  INSERT INTO public.promo_cards (template, title, placement, starts_at, ends_at, is_active)
  VALUES ('glow_tile', 'AP3 Active Card', 'home', now() - interval '1 hour', now() + interval '1 hour', true)
  RETURNING id INTO active_id;

  INSERT INTO public.promo_cards (template, title, placement, is_active)
  VALUES ('glow_tile', 'AP3 Other Placement Card', 'games', true)
  RETURNING id INTO other_placement_id;

  SELECT bool_or(id = future_id) INTO found_future FROM public.get_active_cards('home');
  IF coalesce(found_future, false) THEN
    RAISE EXCEPTION 'FAIL: get_active_cards(''home'') returned a card with a future starts_at';
  END IF;

  SELECT bool_or(id = expired_id) INTO found_expired FROM public.get_active_cards('home');
  IF coalesce(found_expired, false) THEN
    RAISE EXCEPTION 'FAIL: get_active_cards(''home'') returned a card with an expired ends_at';
  END IF;

  SELECT bool_or(id = active_id) INTO found_active FROM public.get_active_cards('home');
  IF NOT coalesce(found_active, false) THEN
    RAISE EXCEPTION 'FAIL: get_active_cards(''home'') did not return the currently-active card';
  END IF;

  SELECT bool_or(id = other_placement_id) INTO found_other_placement FROM public.get_active_cards('home');
  IF coalesce(found_other_placement, false) THEN
    RAISE EXCEPTION 'FAIL: get_active_cards(''home'') returned a card placed in ''games'', not ''home''';
  END IF;

  SELECT bool_or(id = other_placement_id) INTO found_other_placement FROM public.get_active_cards('games');
  IF NOT coalesce(found_other_placement, false) THEN
    RAISE EXCEPTION 'FAIL: get_active_cards(''games'') did not return the card placed in ''games''';
  END IF;
  RAISE NOTICE 'PASS: get_active_cards excludes a not-yet-started and an expired card, includes a currently-active one, and filters by placement';

  ---------------------------------------------------------- 4. direct writes blocked
  SET LOCAL ROLE authenticated;
  BEGIN
    INSERT INTO public.festival_cards (festival_key, template, title) VALUES (any_festival_key, 'glow_tile', 'Forged');
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: direct INSERT into festival_cards as authenticated was not rejected';
  END IF;

  SET LOCAL ROLE anon;
  BEGIN
    INSERT INTO public.festival_cards (festival_key, template, title) VALUES (any_festival_key, 'glow_tile', 'Forged');
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: direct INSERT into festival_cards as anon was not rejected';
  END IF;

  SET LOCAL ROLE authenticated;
  BEGIN
    INSERT INTO public.promo_cards (template, title) VALUES ('glow_tile', 'Forged');
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: direct INSERT into promo_cards as authenticated was not rejected';
  END IF;

  SET LOCAL ROLE anon;
  BEGIN
    INSERT INTO public.promo_cards (template, title) VALUES ('glow_tile', 'Forged');
    write_blocked := false;
  EXCEPTION WHEN insufficient_privilege THEN
    write_blocked := true;
  END;
  RESET ROLE;
  IF NOT write_blocked THEN
    RAISE EXCEPTION 'FAIL: direct INSERT into promo_cards as anon was not rejected';
  END IF;
  RAISE NOTICE 'PASS: direct client INSERT into festival_cards and promo_cards (authenticated and anon) all fail';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
