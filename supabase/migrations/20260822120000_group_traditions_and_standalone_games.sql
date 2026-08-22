-- ---------------------------------------------------------------------------
-- P25: group traditions column + standalone (event-less) game sessions
--
-- 1. public.groups.traditions
--    The frontend has been storing traditions inside groups.description as a
--    documented workaround, which collides with a real group description.
--    Give traditions its own nullable column. No data migration: existing
--    descriptions are left untouched and the frontend moves over separately.
--
-- 2. public.game_sessions.event_id becomes nullable
--    A null event_id means "standalone group game" — a game played outside any
--    party. The six host_create_*_session RPCs take p_event_id as optional and
--    gain a trailing p_group_id used to authorise standalone creation.
--
-- Additive and idempotent where possible. No data migration.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. groups.traditions
-- ---------------------------------------------------------------------------
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS traditions text;

COMMENT ON COLUMN public.groups.traditions IS
  'Free-text group traditions/rituals. Distinct from groups.description, which '
  'previously doubled as the traditions store as a frontend workaround.';

-- RLS note: the existing policies on public.groups are row-level and
-- column-agnostic, so they cover the new column without change --
--   groups_update_host : USING/WITH CHECK (host_id = auth.uid())
--                        -- equivalent to is_group_host(id, auth.uid()),
--                        -- which reads the same groups.host_id -> host can
--                        -- write traditions.
--   groups_read_member : USING (is_group_member(id, auth.uid())
--                               OR host_id = auth.uid())
--                        -- members can read traditions.
-- public.groups also carries table-level GRANTs (not column-level), so the new
-- column inherits them and needs no additional GRANT.

-- ---------------------------------------------------------------------------
-- 2. game_sessions.event_id nullable
-- ---------------------------------------------------------------------------
ALTER TABLE public.game_sessions
  ALTER COLUMN event_id DROP NOT NULL;

COMMENT ON COLUMN public.game_sessions.event_id IS
  'Party this session belongs to. NULL = standalone group game, played outside '
  'any event. The FK to public.events stays ON DELETE CASCADE for non-null rows.';

-- Authorisation is unaffected: every RLS policy on game_sessions and its child
-- tables (game_players, game_prizes, game_rounds, game_claims, game_actions,
-- game_events, tambola_tickets) keys off game_sessions.group_id, never
-- event_id, so standalone sessions are governed exactly like party sessions.
--
-- Readers of event_id are likewise safe: generate_party_recap aggregates game
-- winners with `where s.event_id = p_event_id`, and a NULL event_id simply
-- never matches, so a standalone game contributes no recap rows rather than
-- erroring. idx_game_sessions_event stays valid (btree indexes allow NULLs).

-- ---------------------------------------------------------------------------
-- 3. host_create_*_session — optional p_event_id, new trailing p_group_id
--
-- Each function is dropped and recreated rather than CREATE OR REPLACE'd:
-- adding a parameter changes the signature, and leaving the old signature in
-- place would make existing positional calls ambiguous.
--
-- Shared authorisation shape:
--   p_event_id NOT NULL -> resolve the group through the event (as before);
--                          if p_group_id is also supplied it must agree.
--   p_event_id NULL     -> p_group_id is required and is authorised directly
--                          via is_group_host.
-- Existing callers that pass only p_event_id keep working unchanged.
-- ---------------------------------------------------------------------------

-- 3a. Tambola --------------------------------------------------------------
DROP FUNCTION IF EXISTS public.host_create_tambola_session(uuid, text, text, jsonb);

CREATE OR REPLACE FUNCTION public.host_create_tambola_session(
  p_event_id uuid DEFAULT NULL,
  p_variant text DEFAULT 'classic',
  p_mode text DEFAULT 'manual',
  p_prize_config jsonb DEFAULT NULL,
  p_group_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  e public.events;
  gid uuid;
  sid uuid;
  pack jsonb;
  v public.tambola_variants;
  interval_s integer;
  prize text;
  slots integer;
  sort_i integer := 0;
  kv record;
  item jsonb;
begin
  if p_mode is null or p_mode not in ('manual', 'automatic') then
    raise exception 'Unsupported play mode';
  end if;

  select * into v
  from public.tambola_variants
  where key = p_variant and is_active = true;

  if v.key is null then
    raise exception 'Unsupported or inactive Tambola variant: %', p_variant;
  end if;

  if p_event_id is null then
    if p_group_id is null then
      raise exception 'KITPAT_EVENT_OR_GROUP_REQUIRED';
    end if;
    gid := p_group_id;
  else
    select * into e from public.events where id = p_event_id;
    if e.id is null then
      raise exception 'Host access required';
    end if;
    if p_group_id is not null and p_group_id <> e.group_id then
      raise exception 'KITPAT_GROUP_EVENT_MISMATCH';
    end if;
    gid := e.group_id;
  end if;

  if not public.is_group_host(gid, auth.uid()) then
    raise exception 'Host access required';
  end if;

  select content into pack
  from public.game_theme_packs
  where game_key = 'tambola' and theme_key = p_variant and locale = 'en-IN' and is_active
  limit 1;

  interval_s := coalesce(
    (pack->>'default_interval_seconds')::integer,
    v.default_interval_seconds,
    8
  );

  insert into public.game_sessions(
    event_id, group_id, game_type, variant, play_mode, status, host_id, config, draw_interval_seconds
  ) values (
    p_event_id, gid, 'tambola', p_variant, p_mode, 'lobby', auth.uid(),
    jsonb_build_object('theme_key', p_variant),
    interval_s
  ) returning id into sid;

  if p_prize_config is null then
    -- default prize list from theme pack or variant registry (1 slot each)
    for prize in
      select x from jsonb_array_elements_text(
        coalesce(pack->'default_prizes', v.default_prizes)
      ) as t(x)
    loop
      if prize not in ('early_five','top_line','middle_line','bottom_line','corners','full_house') then
        raise exception 'Unsupported prize %', prize;
      end if;
      sort_i := sort_i + 1;
      insert into public.game_prizes(session_id, prize_type, display_name, total_slots, awarded_slots, sort_order)
      values (sid, prize, initcap(replace(prize, '_', ' ')), 1, 0, sort_i);
    end loop;
  elsif jsonb_typeof(p_prize_config) = 'object' then
    for kv in
      select key as prize_type, value as slots_text
      from jsonb_each_text(p_prize_config)
      order by key
    loop
      prize := kv.prize_type;
      slots := greatest(1, least(100, coalesce(kv.slots_text::integer, 1)));
      if prize not in ('early_five','top_line','middle_line','bottom_line','corners','full_house') then
        raise exception 'Unsupported prize %', prize;
      end if;
      sort_i := sort_i + 1;
      insert into public.game_prizes(session_id, prize_type, display_name, total_slots, awarded_slots, sort_order)
      values (sid, prize, initcap(replace(prize, '_', ' ')), slots, 0, sort_i);
    end loop;
  elsif jsonb_typeof(p_prize_config) = 'array' then
    for item in select * from jsonb_array_elements(p_prize_config)
    loop
      prize := item->>'type';
      slots := greatest(1, least(100, coalesce((item->>'slots')::integer, 1)));
      if prize not in ('early_five','top_line','middle_line','bottom_line','corners','full_house') then
        raise exception 'Unsupported prize %', prize;
      end if;
      sort_i := sort_i + 1;
      insert into public.game_prizes(session_id, prize_type, display_name, total_slots, awarded_slots, sort_order)
      values (sid, prize, initcap(replace(prize, '_', ' ')), slots, 0, sort_i);
    end loop;
  else
    raise exception 'prize_config must be a JSON object or array';
  end if;

  if sort_i = 0 then
    raise exception 'prize_config produced no prizes';
  end if;

  insert into public.game_events(session_id, event_type, actor_id, payload)
  values (
    sid, 'session_created', auth.uid(),
    jsonb_build_object(
      'variant', p_variant,
      'play_mode', p_mode,
      'prize_count', sort_i,
      'standalone', p_event_id is null
    )
  );

  return sid;
end;
$$;

COMMENT ON FUNCTION public.host_create_tambola_session(uuid, text, text, jsonb, uuid) IS
  'Host: create a Tambola lobby. p_event_id NULL + p_group_id = standalone group game.';

REVOKE ALL ON FUNCTION public.host_create_tambola_session(uuid, text, text, jsonb, uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.host_create_tambola_session(uuid, text, text, jsonb, uuid) TO authenticated;
GRANT ALL ON FUNCTION public.host_create_tambola_session(uuid, text, text, jsonb, uuid) TO service_role;

-- 3b. Rapid Fire ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.host_create_rf_session(uuid, text, jsonb);

CREATE OR REPLACE FUNCTION public.host_create_rf_session(
  p_event_id uuid DEFAULT NULL,
  p_theme_key text DEFAULT 'kitty',
  p_config jsonb DEFAULT NULL,
  p_group_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  e public.events;
  gid uuid;
  sid uuid;
  pack jsonb;
  timer_s integer;
  prompts jsonb;
  cfg jsonb;
BEGIN
  IF auth.uid() IS NULL AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_event_id IS NULL THEN
    IF p_group_id IS NULL THEN
      RAISE EXCEPTION 'KITPAT_EVENT_OR_GROUP_REQUIRED';
    END IF;
    gid := p_group_id;
  ELSE
    SELECT * INTO e FROM public.events WHERE id = p_event_id;
    IF e.id IS NULL THEN
      RAISE EXCEPTION 'Host access required';
    END IF;
    IF p_group_id IS NOT NULL AND p_group_id <> e.group_id THEN
      RAISE EXCEPTION 'KITPAT_GROUP_EVENT_MISMATCH';
    END IF;
    gid := e.group_id;
  END IF;

  IF NOT public.is_group_host(gid, auth.uid()) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;

  SELECT content INTO pack
  FROM public.game_theme_packs
  WHERE game_key = 'rapid_fire'
    AND theme_key = p_theme_key
    AND locale = 'en-IN'
    AND is_active
  LIMIT 1;

  IF pack IS NULL THEN
    RAISE EXCEPTION 'Unsupported or inactive rapid_fire theme: %', p_theme_key;
  END IF;

  prompts := pack->'prompts';
  IF prompts IS NULL OR jsonb_typeof(prompts) <> 'array' OR jsonb_array_length(prompts) < 1 THEN
    RAISE EXCEPTION 'Theme % has no prompts', p_theme_key;
  END IF;

  timer_s := coalesce(
    (p_config->>'timer_seconds')::integer,
    (pack->>'timer_seconds')::integer,
    10
  );
  timer_s := greatest(3, least(60, timer_s));

  cfg := coalesce(p_config, '{}'::jsonb) || jsonb_build_object(
    'theme_key', p_theme_key,
    'tone', pack->>'tone',
    'timer_seconds', timer_s,
    'prompts', prompts,
    'prompt_cursor', 0
  );

  INSERT INTO public.game_sessions(
    event_id, group_id, game_type, variant, play_mode, status, host_id, config,
    draw_interval_seconds, current_round
  ) VALUES (
    p_event_id, gid, 'rapid_fire', p_theme_key, 'manual', 'lobby', auth.uid(), cfg,
    timer_s, 0
  ) RETURNING id INTO sid;

  -- Seed all group members as invited; host joined
  INSERT INTO public.game_players(session_id, user_id, status, score)
  SELECT sid, m.user_id,
         CASE WHEN m.user_id = auth.uid() THEN 'joined' ELSE 'invited' END,
         0
  FROM public.members m
  WHERE m.group_id = gid
  ON CONFLICT (session_id, user_id) DO UPDATE
    SET status = EXCLUDED.status;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    sid, 'session_created', auth.uid(),
    jsonb_build_object(
      'game_type', 'rapid_fire',
      'theme_key', p_theme_key,
      'timer_seconds', timer_s,
      'prompt_count', jsonb_array_length(prompts),
      'standalone', p_event_id IS NULL
    )
  );

  RETURN sid;
END;
$$;

COMMENT ON FUNCTION public.host_create_rf_session(uuid, text, jsonb, uuid) IS
  'Host: create Rapid Fire lobby, snapshot theme prompts into session.config, seed game_players. '
  'p_event_id NULL + p_group_id = standalone group game.';

REVOKE ALL ON FUNCTION public.host_create_rf_session(uuid, text, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_create_rf_session(uuid, text, jsonb, uuid)
  TO authenticated, service_role;

-- 3c. Emoji Guess -----------------------------------------------------------
DROP FUNCTION IF EXISTS public.host_create_eg_session(uuid, text, jsonb);

CREATE OR REPLACE FUNCTION public.host_create_eg_session(
  p_event_id uuid DEFAULT NULL,
  p_theme_key text DEFAULT 'bollywood',
  p_config jsonb DEFAULT NULL,
  p_group_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  e public.events;
  gid uuid;
  sid uuid;
  pack jsonb;
  timer_s integer;
  prompts jsonb;
  cfg jsonb;
BEGIN
  IF auth.uid() IS NULL AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_event_id IS NULL THEN
    IF p_group_id IS NULL THEN
      RAISE EXCEPTION 'KITPAT_EVENT_OR_GROUP_REQUIRED';
    END IF;
    gid := p_group_id;
  ELSE
    SELECT * INTO e FROM public.events WHERE id = p_event_id;
    IF e.id IS NULL THEN
      RAISE EXCEPTION 'Host access required';
    END IF;
    IF p_group_id IS NOT NULL AND p_group_id <> e.group_id THEN
      RAISE EXCEPTION 'KITPAT_GROUP_EVENT_MISMATCH';
    END IF;
    gid := e.group_id;
  END IF;

  IF NOT public.is_group_host(gid, auth.uid()) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;

  SELECT content INTO pack
  FROM public.game_theme_packs
  WHERE game_key = 'emoji_guess'
    AND theme_key = p_theme_key
    AND locale = 'en-IN'
    AND is_active
  LIMIT 1;

  IF pack IS NULL THEN
    RAISE EXCEPTION 'Unsupported or inactive emoji_guess theme: %', p_theme_key;
  END IF;

  prompts := pack->'prompts';
  IF prompts IS NULL OR jsonb_typeof(prompts) <> 'array' OR jsonb_array_length(prompts) < 1 THEN
    RAISE EXCEPTION 'Theme % has no emoji prompts', p_theme_key;
  END IF;

  timer_s := coalesce(
    (p_config->>'timer_seconds')::integer,
    (pack->>'timer_seconds')::integer,
    20
  );
  timer_s := greatest(3, least(60, timer_s));

  cfg := coalesce(p_config, '{}'::jsonb) || jsonb_build_object(
    'theme_key', p_theme_key,
    'tone', coalesce(pack->>'tone', 'playful'),
    'timer_seconds', timer_s,
    'prompts', prompts,
    'prompt_cursor', 0
  );

  INSERT INTO public.game_sessions(
    event_id, group_id, game_type, variant, play_mode, status, host_id, config,
    draw_interval_seconds, current_round
  ) VALUES (
    p_event_id, gid, 'emoji_guess', p_theme_key, 'manual', 'lobby', auth.uid(), cfg,
    timer_s, 0
  ) RETURNING id INTO sid;

  INSERT INTO public.game_players(session_id, user_id, status, score)
  SELECT sid, m.user_id,
         CASE WHEN m.user_id = auth.uid() THEN 'joined' ELSE 'invited' END,
         0
  FROM public.members m
  WHERE m.group_id = gid
  ON CONFLICT (session_id, user_id) DO UPDATE
    SET status = EXCLUDED.status;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    sid, 'session_created', auth.uid(),
    jsonb_build_object(
      'game_type', 'emoji_guess',
      'theme_key', p_theme_key,
      'timer_seconds', timer_s,
      'prompt_count', jsonb_array_length(prompts),
      'standalone', p_event_id IS NULL
    )
  );

  RETURN sid;
END;
$$;

COMMENT ON FUNCTION public.host_create_eg_session(uuid, text, jsonb, uuid) IS
  'Host: create Emoji Guess lobby, snapshot theme prompts into session.config, seed game_players. '
  'p_event_id NULL + p_group_id = standalone group game.';

REVOKE ALL ON FUNCTION public.host_create_eg_session(uuid, text, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_create_eg_session(uuid, text, jsonb, uuid)
  TO authenticated, service_role;

-- 3d. Spin & Dare -----------------------------------------------------------
DROP FUNCTION IF EXISTS public.host_create_spin_session(uuid, text, jsonb);

CREATE OR REPLACE FUNCTION public.host_create_spin_session(
  p_event_id uuid DEFAULT NULL,
  p_theme_key text DEFAULT 'kitty',
  p_config jsonb DEFAULT NULL,
  p_group_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  e public.events;
  gid uuid;
  sid uuid;
  pack jsonb;
  dares jsonb;
  skip_allowance integer;
  cfg jsonb;
BEGIN
  IF auth.uid() IS NULL AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_event_id IS NULL THEN
    IF p_group_id IS NULL THEN
      RAISE EXCEPTION 'KITPAT_EVENT_OR_GROUP_REQUIRED';
    END IF;
    gid := p_group_id;
  ELSE
    SELECT * INTO e FROM public.events WHERE id = p_event_id;
    IF e.id IS NULL THEN
      RAISE EXCEPTION 'Host access required';
    END IF;
    IF p_group_id IS NOT NULL AND p_group_id <> e.group_id THEN
      RAISE EXCEPTION 'KITPAT_GROUP_EVENT_MISMATCH';
    END IF;
    gid := e.group_id;
  END IF;

  IF NOT public.is_group_host(gid, auth.uid()) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;

  SELECT content INTO pack
  FROM public.game_theme_packs
  WHERE game_key = 'spin_dare'
    AND theme_key = p_theme_key
    AND locale = 'en-IN'
    AND is_active
  LIMIT 1;

  IF pack IS NULL THEN
    RAISE EXCEPTION 'Unsupported or inactive spin_dare theme: %', p_theme_key;
  END IF;

  dares := pack->'dares';
  IF dares IS NULL OR jsonb_typeof(dares) <> 'array' OR jsonb_array_length(dares) < 1 THEN
    RAISE EXCEPTION 'Theme % has no dares', p_theme_key;
  END IF;

  skip_allowance := coalesce(
    (p_config->>'skip_allowance')::integer,
    (pack->>'skip_allowance')::integer,
    1
  );
  skip_allowance := greatest(0, least(20, skip_allowance));

  cfg := coalesce(p_config, '{}'::jsonb) || jsonb_build_object(
    'theme_key', p_theme_key,
    'tone', coalesce(pack->>'tone', 'witty'),
    'skip_allowance', skip_allowance,
    'dares', dares,
    'used_dare_indices', '[]'::jsonb
  );

  INSERT INTO public.game_sessions(
    event_id, group_id, game_type, variant, play_mode, status, host_id, config,
    draw_interval_seconds, current_round
  ) VALUES (
    p_event_id, gid, 'spin_dare', p_theme_key, 'manual', 'lobby', auth.uid(), cfg,
    8, 0
  ) RETURNING id INTO sid;

  INSERT INTO public.game_players(session_id, user_id, status, score)
  SELECT sid, m.user_id,
         CASE WHEN m.user_id = auth.uid() THEN 'joined' ELSE 'invited' END,
         0
  FROM public.members m
  WHERE m.group_id = gid
  ON CONFLICT (session_id, user_id) DO UPDATE
    SET status = EXCLUDED.status;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    sid, 'session_created', auth.uid(),
    jsonb_build_object(
      'game_type', 'spin_dare',
      'theme_key', p_theme_key,
      'skip_allowance', skip_allowance,
      'dare_count', jsonb_array_length(dares),
      'standalone', p_event_id IS NULL
    )
  );

  RETURN sid;
END;
$$;

COMMENT ON FUNCTION public.host_create_spin_session(uuid, text, jsonb, uuid) IS
  'Host: create Spin & Dare lobby, snapshot theme dares into session.config, seed game_players. '
  'p_event_id NULL + p_group_id = standalone group game.';

REVOKE ALL ON FUNCTION public.host_create_spin_session(uuid, text, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_create_spin_session(uuid, text, jsonb, uuid)
  TO authenticated, service_role;

-- 3e. Pass the Parcel -------------------------------------------------------
DROP FUNCTION IF EXISTS public.host_create_ptp_session(uuid, text, jsonb);

CREATE OR REPLACE FUNCTION public.host_create_ptp_session(
  p_event_id uuid DEFAULT NULL,
  p_theme_key text DEFAULT 'festival',
  p_config jsonb DEFAULT NULL,
  p_group_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  e public.events;
  gid uuid;
  sid uuid;
  pack jsonb;
  challenges jsonb;
  tmin integer;
  tmax integer;
  cfg jsonb;
BEGIN
  IF auth.uid() IS NULL AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_event_id IS NULL THEN
    IF p_group_id IS NULL THEN
      RAISE EXCEPTION 'KITPAT_EVENT_OR_GROUP_REQUIRED';
    END IF;
    gid := p_group_id;
  ELSE
    SELECT * INTO e FROM public.events WHERE id = p_event_id;
    IF e.id IS NULL THEN
      RAISE EXCEPTION 'Host access required';
    END IF;
    IF p_group_id IS NOT NULL AND p_group_id <> e.group_id THEN
      RAISE EXCEPTION 'KITPAT_GROUP_EVENT_MISMATCH';
    END IF;
    gid := e.group_id;
  END IF;

  IF NOT public.is_group_host(gid, auth.uid()) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;

  SELECT content INTO pack
  FROM public.game_theme_packs
  WHERE game_key = 'pass_the_parcel'
    AND theme_key = p_theme_key
    AND locale = 'en-IN'
    AND is_active
  LIMIT 1;

  IF pack IS NULL THEN
    RAISE EXCEPTION 'Unsupported or inactive pass_the_parcel theme: %', p_theme_key;
  END IF;

  challenges := pack->'challenges';
  IF challenges IS NULL OR jsonb_typeof(challenges) <> 'array' OR jsonb_array_length(challenges) < 1 THEN
    RAISE EXCEPTION 'Theme % has no challenges', p_theme_key;
  END IF;

  tmin := coalesce(
    (p_config->>'timer_min_seconds')::integer,
    (pack->>'timer_min_seconds')::integer,
    8
  );
  tmax := coalesce(
    (p_config->>'timer_max_seconds')::integer,
    (pack->>'timer_max_seconds')::integer,
    30
  );
  tmin := greatest(3, least(60, tmin));
  tmax := greatest(tmin, least(60, tmax));

  cfg := coalesce(p_config, '{}'::jsonb) || jsonb_build_object(
    'theme_key', p_theme_key,
    'tone', coalesce(pack->>'tone', 'festive'),
    'timer_min_seconds', tmin,
    'timer_max_seconds', tmax,
    'challenges', challenges,
    'used_challenge_indices', '[]'::jsonb
  );

  INSERT INTO public.game_sessions(
    event_id, group_id, game_type, variant, play_mode, status, host_id, config,
    draw_interval_seconds, current_round
  ) VALUES (
    p_event_id, gid, 'pass_the_parcel', p_theme_key, 'manual', 'lobby', auth.uid(), cfg,
    greatest(3, least(60, tmax)), 0
  ) RETURNING id INTO sid;

  INSERT INTO public.game_players(session_id, user_id, status, score)
  SELECT sid, m.user_id,
         CASE WHEN m.user_id = auth.uid() THEN 'joined' ELSE 'invited' END,
         0
  FROM public.members m
  WHERE m.group_id = gid
  ON CONFLICT (session_id, user_id) DO UPDATE
    SET status = EXCLUDED.status;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    sid, 'session_created', auth.uid(),
    jsonb_build_object(
      'game_type', 'pass_the_parcel',
      'theme_key', p_theme_key,
      'timer_min_seconds', tmin,
      'timer_max_seconds', tmax,
      'challenge_count', jsonb_array_length(challenges),
      'standalone', p_event_id IS NULL
    )
  );

  RETURN sid;
END;
$$;

COMMENT ON FUNCTION public.host_create_ptp_session(uuid, text, jsonb, uuid) IS
  'Host: create Pass the Parcel lobby, snapshot theme challenges into session.config, seed game_players. '
  'p_event_id NULL + p_group_id = standalone group game.';

REVOKE ALL ON FUNCTION public.host_create_ptp_session(uuid, text, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_create_ptp_session(uuid, text, jsonb, uuid)
  TO authenticated, service_role;

-- 3f. Who Knows Who ---------------------------------------------------------
DROP FUNCTION IF EXISTS public.host_create_wkw_session(uuid, text, jsonb);

CREATE OR REPLACE FUNCTION public.host_create_wkw_session(
  p_event_id uuid DEFAULT NULL,
  p_theme_key text DEFAULT 'group_memory',
  p_config jsonb DEFAULT NULL,
  p_group_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  e public.events;
  gid uuid;
  sid uuid;
  pack jsonb;
  prompts jsonb;
  timer_s integer;
  privacy text;
  cfg jsonb;
BEGIN
  IF auth.uid() IS NULL AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  IF p_event_id IS NULL THEN
    IF p_group_id IS NULL THEN
      RAISE EXCEPTION 'KITPAT_EVENT_OR_GROUP_REQUIRED';
    END IF;
    gid := p_group_id;
  ELSE
    SELECT * INTO e FROM public.events WHERE id = p_event_id;
    IF e.id IS NULL THEN
      RAISE EXCEPTION 'Host access required';
    END IF;
    IF p_group_id IS NOT NULL AND p_group_id <> e.group_id THEN
      RAISE EXCEPTION 'KITPAT_GROUP_EVENT_MISMATCH';
    END IF;
    gid := e.group_id;
  END IF;

  IF NOT public.is_group_host(gid, auth.uid()) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;

  SELECT content INTO pack
  FROM public.game_theme_packs
  WHERE game_key = 'who_knows_who'
    AND theme_key = p_theme_key
    AND locale = 'en-IN'
    AND is_active
  LIMIT 1;

  IF pack IS NULL THEN
    RAISE EXCEPTION 'Unsupported or inactive who_knows_who theme: %', p_theme_key;
  END IF;

  prompts := pack->'prompts';
  IF prompts IS NULL OR jsonb_typeof(prompts) <> 'array' OR jsonb_array_length(prompts) < 1 THEN
    RAISE EXCEPTION 'Theme % has no prompts', p_theme_key;
  END IF;

  timer_s := coalesce(
    (p_config->>'timer_seconds')::integer,
    (pack->>'timer_seconds')::integer,
    15
  );
  timer_s := greatest(3, least(60, timer_s));
  privacy := coalesce(p_config->>'privacy', pack->>'privacy', 'consent_required');

  cfg := coalesce(p_config, '{}'::jsonb) || jsonb_build_object(
    'theme_key', p_theme_key,
    'tone', coalesce(pack->>'tone', 'warm'),
    'privacy', privacy,
    'timer_seconds', timer_s,
    'prompts', prompts,
    'prompt_cursor', 0
  );

  INSERT INTO public.game_sessions(
    event_id, group_id, game_type, variant, play_mode, status, host_id, config,
    draw_interval_seconds, current_round
  ) VALUES (
    p_event_id, gid, 'who_knows_who', p_theme_key, 'manual', 'lobby', auth.uid(), cfg,
    timer_s, 0
  ) RETURNING id INTO sid;

  INSERT INTO public.game_players(session_id, user_id, status, score)
  SELECT sid, m.user_id,
         CASE WHEN m.user_id = auth.uid() THEN 'joined' ELSE 'invited' END,
         0
  FROM public.members m
  WHERE m.group_id = gid
  ON CONFLICT (session_id, user_id) DO UPDATE
    SET status = EXCLUDED.status;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    sid, 'session_created', auth.uid(),
    jsonb_build_object(
      'game_type', 'who_knows_who',
      'theme_key', p_theme_key,
      'privacy', privacy,
      'timer_seconds', timer_s,
      'prompt_count', jsonb_array_length(prompts),
      'standalone', p_event_id IS NULL
    )
  );

  RETURN sid;
END;
$$;

COMMENT ON FUNCTION public.host_create_wkw_session(uuid, text, jsonb, uuid) IS
  'Host: create Who Knows Who lobby, snapshot theme prompts into session.config, seed game_players. '
  'p_event_id NULL + p_group_id = standalone group game.';

REVOKE ALL ON FUNCTION public.host_create_wkw_session(uuid, text, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_create_wkw_session(uuid, text, jsonb, uuid)
  TO authenticated, service_role;
