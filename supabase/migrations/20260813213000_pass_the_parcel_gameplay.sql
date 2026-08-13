-- P22: Pass the Parcel gameplay (P18/P21 pattern).
-- Flow: host_create_ptp_session → join_ptp_session → host_start_ptp_pass
--       (RNG stop in [timer_min,timer_max], random holder + challenge)
--       → complete_ptp_challenge(round_id, outcome done|skip) → host_end_ptp_session.
-- Scoring: done = challenge points; skip = 0.


UPDATE public.game_theme_packs
SET content = '{"tone":"festive","timer_min_seconds":8,"timer_max_seconds":30,"challenges":[{"text":"Wish everyone with a festival greeting.","points":10},{"text":"Mime lighting a diya carefully (no real flame).","points":10},{"text":"Teach one tiny garba step.","points":10},{"text":"Share a childhood festival memory (20 sec).","points":10},{"text":"Name three celebration sweets.","points":10},{"text":"Lead a soft fireworks countdown.","points":10},{"text":"Describe a dream festive thali in five words.","points":10},{"text":"Mime flying a kite for 5 seconds.","points":10},{"text":"Do a gentle rangoli swirl in the air.","points":10},{"text":"Offer imaginary mithai to two people.","points":10},{"text":"Give a toast starting with ''May this season…''.","points":10},{"text":"Name two harvest festivals.","points":10},{"text":"Mime wrapping a gift, then fixing it.","points":10},{"text":"Invent a micro-festival name for this group.","points":10},{"text":"Lead a 5-second cheer for the hosts.","points":10},{"text":"Share a festival food you could eat weekly.","points":10},{"text":"Wish the host in two languages you know.","points":10},{"text":"Mime hanging a toran at a doorway.","points":10},{"text":"Describe a festive outfit using only colors.","points":10},{"text":"Clap softly, then louder, then stop together.","points":10},{"text":"Share one gratitude line for the table.","points":10},{"text":"Act out first-rain-of-season joy.","points":10},{"text":"Invent a hashtag for tonight''s celebration.","points":10},{"text":"Namaste the person on your left and right.","points":10},{"text":"End with an air ''shagun'' envelope high-five.","points":10},{"text":"Share your favorite festival smell (cardamom, incense…).","points":10},{"text":"Mime carefully placing a diya in a row.","points":10},{"text":"Teach a one-beat Holi clap.","points":10},{"text":"Name a festival you want to experience next year.","points":10},{"text":"Describe fireworks using only sound effects (keep short).","points":10},{"text":"Offer a virtual laddoo to the quietest person.","points":10},{"text":"Lead a bilingual ''happy celebrations'' chant.","points":10},{"text":"Sketch a tiny rangoli shape with a finger on the table.","points":10}]}'::jsonb,
    rules_text = 'Start the round and pass the parcel. Server picks a random stop; the holder completes a family-safe challenge.',
    name = 'Festival Parcel'
WHERE game_key = 'pass_the_parcel' AND theme_key = 'festival' AND locale = 'en-IN';

INSERT INTO public.game_theme_packs (game_key, theme_key, locale, is_active, name, rules_text, content)
VALUES (
  'pass_the_parcel', 'kitty', 'en-IN', true,
  'Kitty Parcel',
  'Pass the parcel with kitty-party challenge cards. Server controls the random stop.',
  '{"tone":"witty","timer_min_seconds":8,"timer_max_seconds":30,"challenges":[{"text":"Lead a 10-second cheer for the current host.","points":10},{"text":"Compliment three people using only food words.","points":10},{"text":"Mime pouring chai for the whole circle.","points":10},{"text":"Share one wholesome group-chat moment.","points":10},{"text":"Do your best polite ''I''ll be five minutes late'' voice.","points":10},{"text":"Invent a five-word slogan for this kitty.","points":10},{"text":"High-five everyone within reach quickly.","points":10},{"text":"Name three snacks that vanish first at meets.","points":10},{"text":"Give the host a tiny mock award speech.","points":10},{"text":"Swap a fun fact about yourself in one sentence.","points":10},{"text":"Lead a 5-second group stretch.","points":10},{"text":"Act out ''fashionably late'' in three poses.","points":10},{"text":"Tell a grandparent-safe one-line joke.","points":10},{"text":"Pass an imaginary parcel with exaggerated care.","points":10},{"text":"Rate tonight''s vibes out of 10 like a food critic.","points":10},{"text":"Hum a birthday tune for 5 seconds.","points":10},{"text":"Name everyone at the table clockwise.","points":10},{"text":"Propose a silly rule that lasts one round.","points":10},{"text":"Do a silent thank-you bow to the cook/host.","points":10},{"text":"Describe your go-to party snack dramatically.","points":10},{"text":"Clap a rhythm and have one person copy it.","points":10},{"text":"Offer an air high-five ''shagun'' to two friends.","points":10},{"text":"Share one thing you''re grateful for this month.","points":10},{"text":"Strike a silly selfie pose countdown from 3.","points":10},{"text":"Declare a 10-second phone-down challenge for yourself.","points":10},{"text":"Mime settling a bill without speaking.","points":10},{"text":"Compliment the décor like a lifestyle reel.","points":10},{"text":"Guess who brought the best snack energy tonight (kindly).","points":10},{"text":"Mime hunting for the Wi-Fi password.","points":10},{"text":"Lead a toast to friendships that survived group chats.","points":10},{"text":"Do your best ''RSVP yes then forgot'' apology (funny).","points":10},{"text":"Pass a compliment around the circle once.","points":10},{"text":"Name a song that always starts the dancing.","points":10},{"text":"Act out carrying too many return gifts.","points":10}]}'::jsonb
)
ON CONFLICT (game_key, theme_key, locale) DO UPDATE SET
  content = EXCLUDED.content,
  is_active = true,
  name = EXCLUDED.name,
  rules_text = EXCLUDED.rules_text;

INSERT INTO public.game_theme_packs (game_key, theme_key, locale, is_active, name, rules_text, content)
VALUES (
  'pass_the_parcel', 'bollywood', 'en-IN', true,
  'Bollywood Parcel',
  'Pass the parcel with film-party challenge cards. Server controls the random stop.',
  '{"tone":"dramatic","timer_min_seconds":8,"timer_max_seconds":30,"challenges":[{"text":"Deliver a dramatic film-set entry line.","points":10},{"text":"Sing one clean line from any film song.","points":10},{"text":"Strike three hero/heroine poses.","points":10},{"text":"Narrate the last 20 seconds as a trailer voice.","points":10},{"text":"Mime a train goodbye without words.","points":10},{"text":"Say ''Picture abhi baaki hai…'' with drama.","points":10},{"text":"Dance eight counts to an imaginary beat.","points":10},{"text":"Present a pretend Filmfare to someone here.","points":10},{"text":"Name five films that start with D (try!).","points":10},{"text":"Do a light villain laugh (keep it playful).","points":10},{"text":"Mime interval popcorn service.","points":10},{"text":"Cast the table into a heist-movie crew.","points":10},{"text":"Hum a film theme for 5 seconds.","points":10},{"text":"Act out a rain-song with only hand gestures.","points":10},{"text":"Give a Chak De style pep talk (15 seconds).","points":10},{"text":"Invent a sequel title for a classic film.","points":10},{"text":"Bow like you just finished a stage show.","points":10},{"text":"Speak your next sentence as a movie title mashup.","points":10},{"text":"Do clapboard ''Action!'' and ''Cut!''.","points":10},{"text":"Describe your day as a two-line synopsis.","points":10},{"text":"Mime a slow-motion dialogue reaction.","points":10},{"text":"Name three feel-good films fast.","points":10},{"text":"Award ''best supporting friend'' to someone.","points":10},{"text":"Recreate a mustard-field run in place (5 sec).","points":10},{"text":"End with a clean punchy dialogue you invent.","points":10},{"text":"Mime a red-carpet wave for 5 seconds.","points":10},{"text":"Give an awards-night thank-you speech (15 sec).","points":10},{"text":"Name a song that always makes this group dance.","points":10},{"text":"Act out forgetting your dialogue, then recovering.","points":10},{"text":"Pick a co-star from the table and freeze-frame a poster pose.","points":10},{"text":"Narrate a interval snack ad in a radio voice.","points":10},{"text":"Do a silent background-dancer groove for 5 seconds.","points":10},{"text":"Declare the ''interval winner'' of tonight''s vibes.","points":10}]}'::jsonb
)
ON CONFLICT (game_key, theme_key, locale) DO UPDATE SET
  content = EXCLUDED.content,
  is_active = true,
  name = EXCLUDED.name,
  rules_text = EXCLUDED.rules_text;


-- ---------------------------------------------------------------------------
-- 1. host_create_ptp_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_create_ptp_session(
  p_event_id uuid,
  p_theme_key text DEFAULT 'festival',
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
  challenges jsonb;
  tmin integer;
  tmax integer;
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
    e.id, e.group_id, 'pass_the_parcel', p_theme_key, 'manual', 'lobby', auth.uid(), cfg,
    greatest(3, least(60, tmax)), 0
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
      'game_type', 'pass_the_parcel',
      'theme_key', p_theme_key,
      'timer_min_seconds', tmin,
      'timer_max_seconds', tmax,
      'challenge_count', jsonb_array_length(challenges)
    )
  );

  RETURN sid;
END;
$$;

COMMENT ON FUNCTION public.host_create_ptp_session(uuid, text, jsonb) IS
  'Host: create Pass the Parcel lobby, snapshot challenges + timer range, seed players.';

REVOKE ALL ON FUNCTION public.host_create_ptp_session(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_create_ptp_session(uuid, text, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. join_ptp_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_ptp_session(p_session_id uuid)
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
  IF s.id IS NULL OR s.game_type <> 'pass_the_parcel' THEN
    RAISE EXCEPTION 'Pass the Parcel session not found';
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

REVOKE ALL ON FUNCTION public.join_ptp_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_ptp_session(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. host_start_ptp_pass
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_start_ptp_pass(p_session_id uuid)
RETURNS public.game_rounds
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s public.game_sessions;
  challenges jsonb;
  used jsonb;
  available int[];
  pick_idx integer;
  challenge jsonb;
  holder uuid;
  tmin integer;
  tmax integer;
  stop_secs integer;
  r public.game_rounds;
  next_no integer;
  active_count integer;
BEGIN
  IF auth.uid() IS NULL AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = p_session_id FOR UPDATE;
  IF s.id IS NULL OR s.game_type <> 'pass_the_parcel' THEN
    RAISE EXCEPTION 'Pass the Parcel session not found';
  END IF;
  IF NOT public.is_group_host(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;
  IF s.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'Session already ended';
  END IF;

  SELECT count(*) INTO active_count
  FROM public.game_rounds
  WHERE session_id = p_session_id AND status = 'active';
  IF active_count > 0 THEN
    RAISE EXCEPTION 'Complete the active challenge before starting another pass';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.game_players
    WHERE session_id = p_session_id AND status = 'joined'
  ) THEN
    RAISE EXCEPTION 'No joined players for the parcel';
  END IF;

  challenges := s.config->'challenges';
  used := coalesce(s.config->'used_challenge_indices', '[]'::jsonb);
  tmin := coalesce((s.config->>'timer_min_seconds')::integer, 8);
  tmax := coalesce((s.config->>'timer_max_seconds')::integer, 30);
  IF tmax < tmin THEN
    tmax := tmin;
  END IF;

  -- Random stop duration inclusive of min/max
  stop_secs := tmin + floor(random() * (tmax - tmin + 1))::integer;

  SELECT coalesce(array_agg(i ORDER BY i), ARRAY[]::int[])
  INTO available
  FROM generate_series(0, jsonb_array_length(challenges) - 1) AS i
  WHERE NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(used) u WHERE u::integer = i
  );

  IF available IS NULL OR cardinality(available) = 0 THEN
    used := '[]'::jsonb;
    SELECT array_agg(i ORDER BY i) INTO available
    FROM generate_series(0, jsonb_array_length(challenges) - 1) AS i;
  END IF;

  pick_idx := available[1 + floor(random() * cardinality(available))::integer];
  challenge := challenges->pick_idx;

  SELECT gp.user_id INTO holder
  FROM public.game_players gp
  WHERE gp.session_id = p_session_id AND gp.status = 'joined'
  ORDER BY random()
  LIMIT 1;

  next_no := coalesce(s.current_round, 0) + 1;

  INSERT INTO public.game_rounds(
    session_id, round_no, status, prompt, answer, started_at, ends_at
  ) VALUES (
    p_session_id,
    next_no,
    'active',
    jsonb_build_object(
      'text', challenge->>'text',
      'points', coalesce((challenge->>'points')::integer, 10),
      'challenge_index', pick_idx,
      'holder_user_id', holder,
      'stop_after_seconds', stop_secs,
      'timer_min_seconds', tmin,
      'timer_max_seconds', tmax
    ),
    jsonb_build_object(
      'holder_user_id', holder,
      'challenge_index', pick_idx,
      'stop_after_seconds', stop_secs
    ),
    now(),
    now() + make_interval(secs => stop_secs)
  ) RETURNING * INTO r;

  used := used || jsonb_build_array(pick_idx);

  UPDATE public.game_sessions
  SET status = 'active',
      current_round = next_no,
      config = s.config || jsonb_build_object('used_challenge_indices', used),
      started_at = coalesce(started_at, now()),
      updated_at = now()
  WHERE id = p_session_id;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    p_session_id, 'parcel_stopped', auth.uid(),
    jsonb_build_object(
      'round_id', r.id,
      'round_no', r.round_no,
      'holder_user_id', holder,
      'stop_after_seconds', stop_secs,
      'text', challenge->>'text',
      'challenge_index', pick_idx,
      'ends_at', r.ends_at
    )
  );

  RETURN r;
END;
$$;

COMMENT ON FUNCTION public.host_start_ptp_pass(uuid) IS
  'Host: RNG stop within theme timer range; assign random holder + challenge card.';

REVOKE ALL ON FUNCTION public.host_start_ptp_pass(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_start_ptp_pass(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. complete_ptp_challenge(round_id, outcome done|skip)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.complete_ptp_challenge(
  p_round_id uuid,
  p_outcome text
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
  holder uuid;
  pts integer;
  score integer := 0;
  v_action_type text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_outcome IS NULL OR p_outcome NOT IN ('done', 'skip') THEN
    RAISE EXCEPTION 'outcome must be done or skip';
  END IF;

  SELECT * INTO r FROM public.game_rounds WHERE id = p_round_id FOR UPDATE;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'Round not found';
  END IF;
  IF r.status <> 'active' THEN
    RAISE EXCEPTION 'Round is not active';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = r.session_id FOR UPDATE;
  IF s.id IS NULL OR s.game_type <> 'pass_the_parcel' THEN
    RAISE EXCEPTION 'Pass the Parcel session not found';
  END IF;
  IF s.status <> 'active' THEN
    RAISE EXCEPTION 'Session is not active';
  END IF;

  holder := coalesce(
    (r.prompt->>'holder_user_id')::uuid,
    (r.answer->>'holder_user_id')::uuid
  );
  IF holder IS NULL THEN
    RAISE EXCEPTION 'Round has no parcel holder';
  END IF;

  IF auth.uid() IS DISTINCT FROM holder
     AND NOT public.is_group_host(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Only the holder or host can complete this challenge';
  END IF;

  IF NOT public.is_group_member(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Group membership required';
  END IF;

  SELECT * INTO pl FROM public.game_players
  WHERE session_id = s.id AND user_id = holder AND status = 'joined';
  IF pl.id IS NULL THEN
    RAISE EXCEPTION 'Holder is not joined';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.game_actions ga
    WHERE ga.round_id = p_round_id AND ga.action_type IN ('ptp_done', 'ptp_skip')
  ) THEN
    RAISE EXCEPTION 'Challenge already completed';
  END IF;

  pts := coalesce((r.prompt->>'points')::integer, 10);
  IF p_outcome = 'done' THEN
    v_action_type := 'ptp_done';
    score := pts;
  ELSE
    v_action_type := 'ptp_skip';
    score := 0;
  END IF;

  INSERT INTO public.game_actions(
    session_id, round_id, user_id, action_type, payload, server_score
  ) VALUES (
    s.id, p_round_id, holder, v_action_type,
    jsonb_build_object(
      'outcome', p_outcome,
      'resolved_by', auth.uid(),
      'holder_user_id', holder
    ),
    score
  ) RETURNING * INTO act;

  IF score > 0 THEN
    UPDATE public.game_players
    SET score = coalesce(pl.score, 0) + act.server_score
    WHERE id = pl.id;
  END IF;

  UPDATE public.game_rounds
  SET status = 'completed',
      completed_at = now(),
      answer = coalesce(r.answer, '{}'::jsonb) || jsonb_build_object(
        'outcome', p_outcome,
        'resolved_by', auth.uid(),
        'server_score', score
      )
  WHERE id = p_round_id;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    s.id, 'challenge_completed', auth.uid(),
    jsonb_build_object(
      'round_id', p_round_id,
      'outcome', p_outcome,
      'holder_user_id', holder,
      'server_score', score
    )
  );

  RETURN act;
END;
$$;

COMMENT ON FUNCTION public.complete_ptp_challenge(uuid, text) IS
  'Holder or host: complete challenge with outcome done (score) or skip (0).';

REVOKE ALL ON FUNCTION public.complete_ptp_challenge(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.complete_ptp_challenge(uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. host_end_ptp_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_end_ptp_session(p_session_id uuid)
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
  IF s.id IS NULL OR s.game_type <> 'pass_the_parcel' THEN
    RAISE EXCEPTION 'Pass the Parcel session not found';
  END IF;
  IF NOT public.is_group_host(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;
  IF s.status = 'completed' THEN
    RAISE EXCEPTION 'Session already completed';
  END IF;

  UPDATE public.game_rounds
  SET status = 'cancelled', completed_at = coalesce(completed_at, now())
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

REVOKE ALL ON FUNCTION public.host_end_ptp_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_end_ptp_session(uuid)
  TO authenticated, service_role;
