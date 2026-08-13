-- P23: Who Knows Who gameplay (P18 pattern) with privacy/consent gating.
-- Theme privacy=consent_required: only serve kind=generic prompts unless the
-- subject member has users.wkw_prompt_consent = true (no consent rows yet →
-- all seeded prompts are generic group-trivia).
-- Scoring: first on-time answer naming a joined player scores; late/invalid=0.

-- Consent column (nullable; null/false = not opted in)
ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS wkw_prompt_consent boolean;

COMMENT ON COLUMN public.users.wkw_prompt_consent IS
  'Opt-in for Who Knows Who prompts about this member. Null/false = not consented.';


UPDATE public.game_theme_packs
SET content = '{"tone":"warm","privacy":"consent_required","timer_seconds":15,"prompts":[{"text":"Who is most likely to arrive fashionably late?","kind":"generic","points":10},{"text":"Who is most likely to start a group chat thread at midnight?","kind":"generic","points":10},{"text":"Who is most likely to forget their contribution until reminded?","kind":"generic","points":10},{"text":"Who is most likely to bring the best snacks?","kind":"generic","points":10},{"text":"Who is most likely to take 100 photos and post none?","kind":"generic","points":10},{"text":"Who is most likely to know every shortcut in the city?","kind":"generic","points":10},{"text":"Who is most likely to plan the next meetup first?","kind":"generic","points":10},{"text":"Who is most likely to laugh the loudest at a bad joke?","kind":"generic","points":10},{"text":"Who is most likely to remember everyone''s food preferences?","kind":"generic","points":10},{"text":"Who is most likely to say ''I''ll be there in 5'' for 40 minutes?","kind":"generic","points":10},{"text":"Who is most likely to start dancing first?","kind":"generic","points":10},{"text":"Who is most likely to settle the bill math correctly?","kind":"generic","points":10},{"text":"Who is most likely to suggest one more round of games?","kind":"generic","points":10},{"text":"Who is most likely to have the phone charger everyone borrows?","kind":"generic","points":10},{"text":"Who is most likely to tell a story that lasts 20 minutes?","kind":"generic","points":10},{"text":"Who is most likely to bring return gifts that everyone loves?","kind":"generic","points":10},{"text":"Who is most likely to keep the group energy high?","kind":"generic","points":10},{"text":"Who is most likely to notice if someone is quiet and check in?","kind":"generic","points":10},{"text":"Who is most likely to invent a new group tradition?","kind":"generic","points":10},{"text":"Who is most likely to win a rapid trivia round?","kind":"generic","points":10},{"text":"Who is most likely to burn the first batch of snacks?","kind":"generic","points":10},{"text":"Who is most likely to organize carpools?","kind":"generic","points":10},{"text":"Who is most likely to remember birthdays without Facebook?","kind":"generic","points":10},{"text":"Who is most likely to turn a dull evening into a party?","kind":"generic","points":10},{"text":"Who is most likely to quote a movie at the perfect moment?","kind":"generic","points":10}]}'::jsonb,
    rules_text = 'Answer before time expires. Generic group-trivia only unless members opt in to personal prompts.',
    name = 'Who Knows Our Gang?'
WHERE game_key = 'who_knows_who' AND theme_key = 'group_memory' AND locale = 'en-IN';

INSERT INTO public.game_theme_packs (game_key, theme_key, locale, is_active, name, rules_text, content)
VALUES (
  'who_knows_who', 'kitty', 'en-IN', true,
  'Who Knows Kitty?',
  'Kitty-party group trivia. Personal member facts require opt-in consent.',
  '{"tone":"witty","privacy":"consent_required","timer_seconds":15,"prompts":[{"text":"Who is most likely to host the next kitty?","kind":"generic","points":10},{"text":"Who is most likely to bring homemade food?","kind":"generic","points":10},{"text":"Who is most likely to start the gossip (kindly)?","kind":"generic","points":10},{"text":"Who is most likely to win the party games?","kind":"generic","points":10},{"text":"Who is most likely to decorate the best?","kind":"generic","points":10},{"text":"Who is most likely to send the payment reminder?","kind":"generic","points":10},{"text":"Who is most likely to choose the restaurant?","kind":"generic","points":10},{"text":"Who is most likely to bring dessert?","kind":"generic","points":10},{"text":"Who is most likely to stay until the end?","kind":"generic","points":10},{"text":"Who is most likely to leave first (with a good excuse)?","kind":"generic","points":10},{"text":"Who is most likely to coordinate outfits?","kind":"generic","points":10},{"text":"Who is most likely to start a gift exchange idea?","kind":"generic","points":10},{"text":"Who is most likely to remember who paid last time?","kind":"generic","points":10},{"text":"Who is most likely to suggest a themed kitty?","kind":"generic","points":10},{"text":"Who is most likely to make everyone try a new dish?","kind":"generic","points":10},{"text":"Who is most likely to keep score during games?","kind":"generic","points":10},{"text":"Who is most likely to bring flowers for the host?","kind":"generic","points":10},{"text":"Who is most likely to start karaoke?","kind":"generic","points":10},{"text":"Who is most likely to plan a surprise for someone?","kind":"generic","points":10},{"text":"Who is most likely to take the group selfie?","kind":"generic","points":10},{"text":"Who is most likely to spill chai and laugh it off?","kind":"generic","points":10},{"text":"Who is most likely to know the best sweet shop nearby?","kind":"generic","points":10},{"text":"Who is most likely to reuse last year''s decorations creatively?","kind":"generic","points":10},{"text":"Who is most likely to write the thank-you message after?","kind":"generic","points":10},{"text":"Who is most likely to propose a charity kitty month?","kind":"generic","points":10}]}'::jsonb
)
ON CONFLICT (game_key, theme_key, locale) DO UPDATE SET
  content = EXCLUDED.content,
  is_active = true,
  name = EXCLUDED.name,
  rules_text = EXCLUDED.rules_text;

INSERT INTO public.game_theme_packs (game_key, theme_key, locale, is_active, name, rules_text, content)
VALUES (
  'who_knows_who', 'bollywood', 'en-IN', true,
  'Who Knows Bollywood Night?',
  'Film-night group trivia. Personal member facts require opt-in consent.',
  '{"tone":"dramatic","privacy":"consent_required","timer_seconds":15,"prompts":[{"text":"Who is most likely to remember every SRK dialogue?","kind":"generic","points":10},{"text":"Who is most likely to cry in a sad film ending?","kind":"generic","points":10},{"text":"Who is most likely to start singing in the car?","kind":"generic","points":10},{"text":"Who is most likely to do a full dance reenactment?","kind":"generic","points":10},{"text":"Who is most likely to binge a trilogy in one weekend?","kind":"generic","points":10},{"text":"Who is most likely to win Bollywood trivia?","kind":"generic","points":10},{"text":"Who is most likely to cast the group in a heist film?","kind":"generic","points":10},{"text":"Who is most likely to quote 3 Idiots under pressure?","kind":"generic","points":10},{"text":"Who is most likely to plan a movie marathon night?","kind":"generic","points":10},{"text":"Who is most likely to argue about the best YRF film?","kind":"generic","points":10},{"text":"Who is most likely to hum the background score mid-conversation?","kind":"generic","points":10},{"text":"Who is most likely to invent a sequel title on the spot?","kind":"generic","points":10},{"text":"Who is most likely to do an awards-show thank-you speech?","kind":"generic","points":10},{"text":"Who is most likely to know obscure 90s songs?","kind":"generic","points":10},{"text":"Who is most likely to pause a film to explain the plot?","kind":"generic","points":10},{"text":"Who is most likely to pick the interval snacks?","kind":"generic","points":10},{"text":"Who is most likely to recreate a rain-song pose?","kind":"generic","points":10},{"text":"Who is most likely to win a dialogue delivery contest?","kind":"generic","points":10},{"text":"Who is most likely to recommend an underrated gem?","kind":"generic","points":10},{"text":"Who is most likely to fall asleep during a slow film?","kind":"generic","points":10},{"text":"Who is most likely to clap in the theatre like it''s premiere night?","kind":"generic","points":10},{"text":"Who is most likely to know the choreographer''s name?","kind":"generic","points":10},{"text":"Who is most likely to do a trailer voice-over for fun?","kind":"generic","points":10},{"text":"Who is most likely to choose the OTT queue for the group?","kind":"generic","points":10},{"text":"Who is most likely to turn a family dinner into a film quiz?","kind":"generic","points":10}]}'::jsonb
)
ON CONFLICT (game_key, theme_key, locale) DO UPDATE SET
  content = EXCLUDED.content,
  is_active = true,
  name = EXCLUDED.name,
  rules_text = EXCLUDED.rules_text;

INSERT INTO public.game_theme_packs (game_key, theme_key, locale, is_active, name, rules_text, content)
VALUES (
  'who_knows_who', 'festival', 'en-IN', true,
  'Who Knows Festival Crew?',
  'Festive group trivia. Personal member facts require opt-in consent.',
  '{"tone":"festive","privacy":"consent_required","timer_seconds":15,"prompts":[{"text":"Who is most likely to send the first festival greeting?","kind":"generic","points":10},{"text":"Who is most likely to host the Holi meetup?","kind":"generic","points":10},{"text":"Who is most likely to make the best mithai platter?","kind":"generic","points":10},{"text":"Who is most likely to go all-out on decorations?","kind":"generic","points":10},{"text":"Who is most likely to know every festival date this year?","kind":"generic","points":10},{"text":"Who is most likely to teach a garba step?","kind":"generic","points":10},{"text":"Who is most likely to fly kites on Sankranti?","kind":"generic","points":10},{"text":"Who is most likely to organize a Secret Santa?","kind":"generic","points":10},{"text":"Who is most likely to bring diyas for everyone?","kind":"generic","points":10},{"text":"Who is most likely to plan a group picnic for harvest season?","kind":"generic","points":10},{"text":"Who is most likely to wear the brightest festive colors?","kind":"generic","points":10},{"text":"Who is most likely to start a festive playlist?","kind":"generic","points":10},{"text":"Who is most likely to remember who gifted what last year?","kind":"generic","points":10},{"text":"Who is most likely to make rangoli at the entrance?","kind":"generic","points":10},{"text":"Who is most likely to host an iftar-friendly get-together?","kind":"generic","points":10},{"text":"Who is most likely to bake something for Christmas?","kind":"generic","points":10},{"text":"Who is most likely to suggest a charity drive for the season?","kind":"generic","points":10},{"text":"Who is most likely to take the best festive group photo?","kind":"generic","points":10},{"text":"Who is most likely to explain a festival tradition to kids?","kind":"generic","points":10},{"text":"Who is most likely to keep the celebration going past midnight?","kind":"generic","points":10},{"text":"Who is most likely to bring homemade namkeen?","kind":"generic","points":10},{"text":"Who is most likely to coordinate matching festive looks?","kind":"generic","points":10},{"text":"Who is most likely to write a sweet group wish message?","kind":"generic","points":10},{"text":"Who is most likely to clean up after the party first?","kind":"generic","points":10},{"text":"Who is most likely to invent a new micro-tradition for this group?","kind":"generic","points":10}]}'::jsonb
)
ON CONFLICT (game_key, theme_key, locale) DO UPDATE SET
  content = EXCLUDED.content,
  is_active = true,
  name = EXCLUDED.name,
  rules_text = EXCLUDED.rules_text;


CREATE OR REPLACE FUNCTION public._wkw_member_consented(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT coalesce(
    (SELECT u.wkw_prompt_consent FROM public.users u WHERE u.id = p_user_id),
    false
  );
$$;

-- ---------------------------------------------------------------------------
-- 1. host_create_wkw_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_create_wkw_session(
  p_event_id uuid,
  p_theme_key text DEFAULT 'group_memory',
  p_config jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  e public.events;
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

  SELECT * INTO e FROM public.events WHERE id = p_event_id;
  IF e.id IS NULL OR NOT public.is_group_host(e.group_id, auth.uid()) THEN
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
    e.id, e.group_id, 'who_knows_who', p_theme_key, 'manual', 'lobby', auth.uid(), cfg,
    timer_s, 0
  ) RETURNING id INTO sid;

  INSERT INTO public.game_players(session_id, user_id, status, score)
  SELECT sid, m.user_id,
         CASE WHEN m.user_id = auth.uid() THEN 'joined' ELSE 'invited' END,
         0
  FROM public.members m
  WHERE m.group_id = e.group_id
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
      'prompt_count', jsonb_array_length(prompts)
    )
  );

  RETURN sid;
END;
$$;

COMMENT ON FUNCTION public.host_create_wkw_session(uuid, text, jsonb) IS
  'Host: create Who Knows Who lobby; snapshots prompts; privacy=consent_required by default.';

REVOKE ALL ON FUNCTION public.host_create_wkw_session(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_create_wkw_session(uuid, text, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. join_wkw_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_wkw_session(p_session_id uuid)
RETURNS public.game_players
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s public.game_sessions;
  row public.game_players;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = p_session_id;
  IF s.id IS NULL OR s.game_type <> 'who_knows_who' THEN
    RAISE EXCEPTION 'Who Knows Who session not found';
  END IF;
  IF s.status NOT IN ('lobby', 'active') THEN
    RAISE EXCEPTION 'Session is not joinable (%)', s.status;
  END IF;
  IF NOT public.is_group_member(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Group membership required';
  END IF;

  INSERT INTO public.game_players(session_id, user_id, status, score)
  VALUES (p_session_id, auth.uid(), 'joined', 0)
  ON CONFLICT (session_id, user_id) DO UPDATE
    SET status = 'joined'
  RETURNING * INTO row;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    p_session_id, 'player_joined', auth.uid(),
    jsonb_build_object('user_id', auth.uid())
  );

  RETURN row;
END;
$$;

REVOKE ALL ON FUNCTION public.join_wkw_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_wkw_session(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. host_next_wkw_round — privacy-filtered prompt advance
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_next_wkw_round(p_session_id uuid)
RETURNS public.game_rounds
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s public.game_sessions;
  prompts jsonb;
  cursor int;
  prompt jsonb;
  kind text;
  subject uuid;
  privacy text;
  timer_s integer;
  r public.game_rounds;
  next_no integer;
  n int;
  guard int := 0;
BEGIN
  IF auth.uid() IS NULL AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = p_session_id FOR UPDATE;
  IF s.id IS NULL OR s.game_type <> 'who_knows_who' THEN
    RAISE EXCEPTION 'Who Knows Who session not found';
  END IF;
  IF NOT public.is_group_host(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;
  IF s.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'Session already ended';
  END IF;

  UPDATE public.game_rounds
  SET status = 'completed',
      completed_at = coalesce(completed_at, now())
  WHERE session_id = p_session_id AND status = 'active';

  prompts := s.config->'prompts';
  privacy := coalesce(s.config->>'privacy', 'consent_required');
  cursor := coalesce((s.config->>'prompt_cursor')::integer, 0);
  n := jsonb_array_length(prompts);

  -- Advance cursor skipping non-consented personal prompts
  LOOP
    IF cursor >= n THEN
      RAISE EXCEPTION 'No more eligible prompts in this session';
    END IF;
    prompt := prompts->cursor;
    kind := coalesce(prompt->>'kind', 'generic');
    subject := NULLIF(prompt->>'subject_user_id', '')::uuid;

    IF kind = 'generic' OR privacy IS DISTINCT FROM 'consent_required' THEN
      EXIT; -- allowed
    ELSIF kind = 'about_member' AND subject IS NOT NULL
          AND public._wkw_member_consented(subject) THEN
      EXIT; -- consented personal prompt
    ELSE
      -- skip non-consented / unknown personal prompt
      cursor := cursor + 1;
      guard := guard + 1;
      IF guard > n + 5 THEN
        RAISE EXCEPTION 'No eligible prompts after privacy filtering';
      END IF;
    END IF;
  END LOOP;

  timer_s := coalesce((s.config->>'timer_seconds')::integer, 15);
  next_no := coalesce(s.current_round, 0) + 1;

  INSERT INTO public.game_rounds(
    session_id, round_no, status, prompt, answer, started_at, ends_at
  ) VALUES (
    p_session_id,
    next_no,
    'active',
    jsonb_build_object(
      'text', prompt->>'text',
      'kind', kind,
      'points', coalesce((prompt->>'points')::integer, 10),
      'index', cursor,
      'subject_user_id', subject
    ),
    jsonb_build_object(
      'answer_type', 'joined_player',
      'expected', prompt->'expected'
    ),
    now(),
    now() + make_interval(secs => timer_s)
  ) RETURNING * INTO r;

  UPDATE public.game_sessions
  SET status = 'active',
      current_round = next_no,
      config = s.config || jsonb_build_object('prompt_cursor', cursor + 1),
      started_at = coalesce(started_at, now()),
      updated_at = now()
  WHERE id = p_session_id;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    p_session_id, 'prompt_started', auth.uid(),
    jsonb_build_object(
      'round_id', r.id,
      'round_no', r.round_no,
      'text', prompt->>'text',
      'kind', kind,
      'ends_at', r.ends_at
    )
  );

  RETURN r;
END;
$$;

REVOKE ALL ON FUNCTION public.host_next_wkw_round(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_next_wkw_round(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. submit_wkw_answer — first valid on-time vote for a joined player
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_wkw_answer(
  p_round_id uuid,
  p_answer jsonb
) RETURNS public.game_actions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  r public.game_rounds;
  s public.game_sessions;
  pl public.game_players;
  act public.game_actions;
  late boolean;
  voted uuid;
  vote_name text;
  valid boolean := false;
  first_win boolean;
  pts integer;
  score integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_answer IS NULL OR jsonb_typeof(p_answer) <> 'object' THEN
    RAISE EXCEPTION 'answer must be a JSON object';
  END IF;

  SELECT * INTO r FROM public.game_rounds WHERE id = p_round_id FOR UPDATE;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'Round not found';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = r.session_id FOR UPDATE;
  IF s.id IS NULL OR s.game_type <> 'who_knows_who' THEN
    RAISE EXCEPTION 'Who Knows Who session not found';
  END IF;
  IF s.status <> 'active' OR r.status <> 'active' THEN
    RAISE EXCEPTION 'Round/session is not active';
  END IF;
  IF NOT public.is_group_member(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Group membership required';
  END IF;

  SELECT * INTO pl FROM public.game_players
  WHERE session_id = s.id AND user_id = auth.uid() AND status = 'joined';
  IF pl.id IS NULL THEN
    RAISE EXCEPTION 'Join the session before answering';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.game_actions ga
    WHERE ga.round_id = p_round_id AND ga.user_id = auth.uid() AND ga.action_type = 'wkw_answer'
  ) THEN
    RAISE EXCEPTION 'Already answered this round';
  END IF;

  late := (r.ends_at IS NOT NULL AND now() > r.ends_at);

  -- Resolve voted player: user_id field, or answer as uuid, or name match
  BEGIN
    voted := NULLIF(p_answer->>'user_id', '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    voted := NULL;
  END;
  IF voted IS NULL THEN
    BEGIN
      voted := NULLIF(p_answer->>'answer', '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      voted := NULL;
    END;
  END IF;
  IF voted IS NULL THEN
    vote_name := public._rf_normalize_answer(
      coalesce(p_answer->>'answer', p_answer->>'name', p_answer->>'text')
    );
    IF vote_name IS NOT NULL AND vote_name <> '' THEN
      SELECT gp.user_id INTO voted
      FROM public.game_players gp
      JOIN public.users u ON u.id = gp.user_id
      WHERE gp.session_id = s.id AND gp.status = 'joined'
        AND public._rf_normalize_answer(u.name) = vote_name
      LIMIT 1;
    END IF;
  END IF;

  IF voted IS NOT NULL THEN
    valid := EXISTS (
      SELECT 1 FROM public.game_players gp
      WHERE gp.session_id = s.id AND gp.user_id = voted AND gp.status = 'joined'
    );
  END IF;

  -- Optional expected answers (trivia facts) via RF matcher
  IF NOT valid AND r.answer->'expected' IS NOT NULL AND jsonb_typeof(r.answer->'expected') <> 'null' THEN
    valid := public._rf_answer_matches(p_answer, r.answer->'expected');
  END IF;

  pts := coalesce((r.prompt->>'points')::integer, 10);
  first_win := false;
  IF valid AND NOT late THEN
    first_win := NOT EXISTS (
      SELECT 1 FROM public.game_actions ga
      WHERE ga.round_id = p_round_id
        AND ga.action_type = 'wkw_answer'
        AND ga.server_score > 0
    );
    IF first_win THEN
      score := pts;
    END IF;
  END IF;

  INSERT INTO public.game_actions(
    session_id, round_id, user_id, action_type, payload, server_score
  ) VALUES (
    s.id, p_round_id, auth.uid(), 'wkw_answer',
    p_answer || jsonb_build_object(
      'late', late,
      'valid', valid,
      'voted_user_id', voted,
      'first_correct', first_win
    ),
    score
  ) RETURNING * INTO act;

  IF score > 0 THEN
    UPDATE public.game_players
    SET score = coalesce(pl.score, 0) + act.server_score
    WHERE id = pl.id;
  END IF;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    s.id, 'response_submitted', auth.uid(),
    jsonb_build_object(
      'round_id', p_round_id,
      'server_score', score,
      'late', late,
      'valid', valid,
      'voted_user_id', voted,
      'first_correct', first_win
    )
  );

  RETURN act;
END;
$$;

COMMENT ON FUNCTION public.submit_wkw_answer(uuid, jsonb) IS
  'Member: vote for a joined player (or match expected). First on-time valid answer scores.';

REVOKE ALL ON FUNCTION public.submit_wkw_answer(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_wkw_answer(uuid, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. host_end_wkw_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_end_wkw_session(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s public.game_sessions;
  winner_id uuid;
  winner_score integer;
  result jsonb;
BEGIN
  IF auth.uid() IS NULL AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = p_session_id FOR UPDATE;
  IF s.id IS NULL OR s.game_type <> 'who_knows_who' THEN
    RAISE EXCEPTION 'Who Knows Who session not found';
  END IF;
  IF NOT public.is_group_host(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;
  IF s.status = 'completed' THEN
    RAISE EXCEPTION 'Session already completed';
  END IF;

  UPDATE public.game_rounds
  SET status = 'completed', completed_at = coalesce(completed_at, now())
  WHERE session_id = p_session_id AND status = 'active';

  SELECT gp.user_id, gp.score
  INTO winner_id, winner_score
  FROM public.game_players gp
  WHERE gp.session_id = p_session_id AND gp.status = 'joined'
  ORDER BY gp.score DESC, gp.joined_at ASC
  LIMIT 1;

  UPDATE public.game_sessions
  SET status = 'completed',
      ended_at = now(),
      updated_at = now(),
      config = s.config || jsonb_build_object(
        'winner_user_id', winner_id,
        'winner_score', winner_score
      )
  WHERE id = p_session_id;

  result := jsonb_build_object(
    'session_id', p_session_id,
    'status', 'completed',
    'winner_user_id', winner_id,
    'winner_score', coalesce(winner_score, 0),
    'standings', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object('user_id', gp.user_id, 'score', gp.score, 'status', gp.status)
        ORDER BY gp.score DESC, gp.joined_at ASC
      )
      FROM public.game_players gp
      WHERE gp.session_id = p_session_id
    ), '[]'::jsonb)
  );

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (p_session_id, 'session_completed', auth.uid(), result);

  RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION public.host_end_wkw_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_end_wkw_session(uuid)
  TO authenticated, service_role;
