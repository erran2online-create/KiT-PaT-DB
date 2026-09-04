-- ---------------------------------------------------------------------------
-- P39: shared per-session number->label map for Bollywood and Kitty Special
-- Tambola, so the host's calling stage and every player's ticket show the
-- exact same film title / festival tile in place of a plain number.
--
-- Does NOT touch draw/claim/verify logic. host_call_tambola_number,
-- mark_tambola_number, host_check_tambola_claim, claim_tambola_prize, and
-- process_due_tambola_auto_draws are all untouched -- the draw order stays
-- server-controlled and unknown to clients exactly as before. The only
-- change to existing behaviour is one added call inside host_start_tambola,
-- after its existing start logic, to fix the label map when the game goes
-- live.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. game_sessions.number_label_map
-- ---------------------------------------------------------------------------
ALTER TABLE public.game_sessions
  ADD COLUMN IF NOT EXISTS number_label_map jsonb;

COMMENT ON COLUMN public.game_sessions.number_label_map IS
  'Shared presentation map for Bollywood/Kitty Special Tambola: {"1".."90": {"label": text, "kind": "film"|"festival"|"plain"}}. Built once by build_session_label_map (called from host_start_tambola) and never reshuffled afterwards. NULL for classic/quick_10 (plain numbers, no label needed).';

-- ---------------------------------------------------------------------------
-- 2. build_session_label_map(p_session_id) -- host-only, idempotent
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.build_session_label_map(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s public.game_sessions;
  films text[];
  shuffled text[];
  festival public.festival_themes;
  festival_key text;
  cur_month integer;
  motif text;
  map jsonb := '{}'::jsonb;
  i integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = p_session_id FOR UPDATE;
  IF s.id IS NULL OR s.game_type <> 'tambola' THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;
  IF NOT public.is_group_host(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'KITPAT_NOT_HOST' USING ERRCODE = 'PT403';
  END IF;

  -- Idempotent: never reshuffle mid-game once a map has been fixed.
  IF s.number_label_map IS NOT NULL THEN
    RETURN s.number_label_map;
  END IF;

  IF s.variant = 'bollywood' THEN
    SELECT ARRAY(SELECT jsonb_array_elements_text(content -> 'films'))
      INTO films
    FROM public.game_theme_packs
    WHERE game_key = 'tambola' AND theme_key = 'bollywood' AND locale = 'en-IN' AND is_active
    LIMIT 1;

    IF films IS NULL OR array_length(films, 1) < 90 THEN
      RAISE EXCEPTION 'KITPAT_FILM_POOL_TOO_SMALL';
    END IF;

    -- films has no duplicate titles (P35), so a random 90-pick without
    -- replacement is automatically 90 distinct titles.
    SELECT ARRAY(SELECT f FROM unnest(films) f ORDER BY random() LIMIT 90) INTO shuffled;

    FOR i IN 1..90 LOOP
      map := map || jsonb_build_object(
        i::text, jsonb_build_object('label', shuffled[i], 'kind', 'film')
      );
    END LOOP;

  ELSIF s.variant = 'kitty_special' THEN
    festival_key := s.config ->> 'festival_key';
    festival := NULL;

    IF festival_key IS NOT NULL THEN
      SELECT * INTO festival FROM public.festival_themes WHERE key = festival_key AND is_active;
    END IF;

    IF festival.key IS NULL THEN
      cur_month := extract(month FROM (now() AT TIME ZONE 'Asia/Kolkata'))::integer;
      SELECT * INTO festival FROM public.get_festival_options(cur_month) LIMIT 1;
    END IF;

    IF festival.key IS NOT NULL THEN
      motif := trim(coalesce(festival.emoji, '') || ' ' || coalesce(festival.name, festival.key));
      FOR i IN 1..90 LOOP
        map := map || jsonb_build_object(
          i::text, jsonb_build_object('label', motif || ' ' || i::text, 'kind', 'festival')
        );
      END LOOP;
    ELSE
      -- No festival resolves for this month/session: fall back to the
      -- group's own memory-context label rather than inventing a festival.
      FOR i IN 1..90 LOOP
        map := map || jsonb_build_object(
          i::text, jsonb_build_object('label', 'Kitty Special ' || i::text, 'kind', 'festival')
        );
      END LOOP;
    END IF;

  ELSE
    -- classic, quick_10, and any other/future variant: plain numbers.
    map := NULL;
  END IF;

  UPDATE public.game_sessions SET number_label_map = map, updated_at = now() WHERE id = p_session_id;

  RETURN map;
END;
$$;

COMMENT ON FUNCTION public.build_session_label_map(uuid) IS
  'Host-only. Builds and fixes game_sessions.number_label_map for a Bollywood (distinct film per number) or Kitty Special (festival tile motif) session. Idempotent -- returns the existing map unchanged if one is already set, never reshuffles mid-game. NULL for classic/quick_10. Errors: KITPAT_UNAUTHENTICATED / KITPAT_NOT_FOUND / KITPAT_NOT_HOST / KITPAT_FILM_POOL_TOO_SMALL.';

REVOKE ALL ON FUNCTION public.build_session_label_map(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.build_session_label_map(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. host_start_tambola -- unchanged existing logic, plus one call to fix
--    the label map once the game goes live. Signature, SECURITY DEFINER,
--    search_path, and grants are all preserved exactly (CREATE OR REPLACE
--    on an unchanged signature does not reset a function's ACL, so the
--    existing REVOKE ALL FROM PUBLIC / GRANT ALL TO authenticated,
--    service_role from the original definition still applies).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."host_start_tambola"("p_session_id" "uuid") RETURNS "public"."game_sessions"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare s public.game_sessions;
begin
 select * into s from public.game_sessions where id=p_session_id for update;
 if s.id is null or s.game_type <> 'tambola' then raise exception 'Tambola session not found'; end if;
 if not public.is_group_host(s.group_id,auth.uid()) then raise exception 'Host access required'; end if;
 if s.status not in ('lobby','paused') then raise exception 'Session cannot be started from %',s.status; end if;
 update public.game_sessions set status='active',started_at=coalesce(started_at,now()),next_auto_draw_at=case when play_mode='automatic' then now() else null end,updated_at=now() where id=p_session_id returning * into s;
 insert into public.game_events(session_id,event_type,actor_id,payload) values(p_session_id,'session_started',auth.uid(),jsonb_build_object('mode',s.play_mode));
 perform public.build_session_label_map(p_session_id);
 select * into s from public.game_sessions where id=p_session_id;
 return s;
end $$;

-- ---------------------------------------------------------------------------
-- 4. get_session_labels(p_session_id) -- member-or-host read
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_session_labels(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s public.game_sessions;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = p_session_id;
  IF s.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  IF NOT (public.is_group_member(s.group_id, auth.uid()) OR public.is_group_host(s.group_id, auth.uid())) THEN
    RAISE EXCEPTION 'KITPAT_NOT_MEMBER' USING ERRCODE = 'PT403';
  END IF;

  RETURN s.number_label_map;
END;
$$;

COMMENT ON FUNCTION public.get_session_labels(uuid) IS
  'Member-or-host read of game_sessions.number_label_map, so a player''s ticket shows the exact same film/festival label the host''s calling stage shows. Errors: KITPAT_UNAUTHENTICATED / KITPAT_NOT_FOUND / KITPAT_NOT_MEMBER.';

-- ---------------------------------------------------------------------------
-- 5. Grants
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.get_session_labels(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_session_labels(uuid) TO authenticated, service_role;
