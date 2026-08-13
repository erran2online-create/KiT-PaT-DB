-- P21: Spin & Dare gameplay (P18/P20 pattern).
-- Flow: host_create_spin_session → join_spin_session → host_spin_dare (RNG dare + player)
--       → resolve_spin_dare(done|skip) → host_end_spin_session.
-- Scoring: done = dare points; skip = 0 and consumes skip_allowance (per player/session).


UPDATE public.game_theme_packs
SET content = '{"tone":"witty","skip_allowance":1,"dares":[{"text":"Do your best impression of the group''s most dramatic payment reminder.","points":10},{"text":"Announce next month''s kitty theme in a news-anchor voice.","points":10},{"text":"Compliment three people using only food metaphors.","points":10},{"text":"Mime ordering chai for the whole table without speaking.","points":10},{"text":"Share one wholesome group chat moment from this year.","points":10},{"text":"Lead a 10-second toast to the current host.","points":10},{"text":"Guess who arrives latest — then apologize to them playfully.","points":10},{"text":"Teach the group your signature clap-cheer.","points":10},{"text":"Swap seats with the person across from you for one round.","points":10},{"text":"Name three snacks that vanished first at the last meet.","points":10},{"text":"Do a silent fashion runway walk to your chair and back.","points":10},{"text":"Invent a slogan for this kitty in under five words.","points":10},{"text":"High-five everyone within reach in 15 seconds.","points":10},{"text":"Tell a one-line joke clean enough for grandparents.","points":10},{"text":"Recount the funniest UPI mix-up without naming names.","points":10},{"text":"Pick a song and hum only the chorus for 10 seconds.","points":10},{"text":"Give the host a mock award speech (20 seconds).","points":10},{"text":"Balance an empty glass on your head for 5 seconds (safely).","points":10},{"text":"Spell your full name backwards out loud.","points":10},{"text":"Act out ''fashionably late'' in three poses.","points":10},{"text":"Compliment the décor like a lifestyle blogger.","points":10},{"text":"Propose a silly new group rule for tonight only.","points":10},{"text":"Do your best ''I''ll pay tomorrow'' voice, then laugh.","points":10},{"text":"Name everyone at the table in alphabetical order.","points":10},{"text":"Lead a 5-second group stretch break.","points":10},{"text":"Take a funny group selfie pose countdown from 3.","points":10},{"text":"Confess your go-to party snack in a dramatic whisper.","points":10},{"text":"Pass an invisible parcel around for 5 seconds.","points":10},{"text":"Rate tonight''s vibes out of 10 like a food critic.","points":10},{"text":"Declare a 10-second phone-free challenge for yourself.","points":10}]}'::jsonb,
    rules_text = 'Spin is server-selected. Complete for points or use skip_allowance. Family-safe.',
    name = 'Kitty Challenge Wheel'
WHERE game_key = 'spin_dare' AND theme_key = 'kitty' AND locale = 'en-IN';

INSERT INTO public.game_theme_packs (game_key, theme_key, locale, is_active, name, rules_text, content)
VALUES (
  'spin_dare', 'bollywood', 'en-IN', true,
  'Bollywood Challenge Wheel',
  'Spin for a dramatic, family-safe film-party dare. Skip allowance applies.',
  '{"tone":"dramatic","skip_allowance":1,"dares":[{"text":"Deliver a dramatic entry line as if you just walked onto a film set.","points":10},{"text":"Sing one line from any Bollywood song (family-friendly).","points":10},{"text":"Strike three iconic hero/heroine poses.","points":10},{"text":"Narrate the last 30 seconds like a movie trailer voice.","points":10},{"text":"Do a slow-motion ''dialogue'' face for 5 seconds.","points":10},{"text":"Name five Bollywood movies that start with D.","points":10},{"text":"Act out a train goodbye scene without words.","points":10},{"text":"Imitate a classic villain laugh (keep it light).","points":10},{"text":"Present an imaginary Filmfare award to someone here.","points":10},{"text":"Dance for 8 counts to an imaginary item song beat.","points":10},{"text":"Say ''Picture abhi baaki hai…'' with full drama.","points":10},{"text":"Mime a rain song using only hand gestures.","points":10},{"text":"Guess a movie from three emoji clues made up on the spot.","points":10},{"text":"Do a news-reporter wrap-up of tonight''s party.","points":10},{"text":"Recreate the DDLJ mustard-field run in place for 5 seconds.","points":10},{"text":"Speak only in movie titles for your next two sentences.","points":10},{"text":"Cast everyone at the table in a heist film role.","points":10},{"text":"Hum the National Anthem vibe but switch to a film theme after 3 notes—then stop politely.","points":10},{"text":"Give a motivational coach pep talk like Chak De.","points":10},{"text":"Act out ''interval time'' like a theatre usher.","points":10},{"text":"Name three SRK films in ten seconds.","points":10},{"text":"Do a silent clap-board ''Action!'' and ''Cut!''.","points":10},{"text":"Invent a sequel title for any classic film.","points":10},{"text":"Bow like you just finished a stage play.","points":10},{"text":"Describe your day as a two-line film synopsis.","points":10},{"text":"Mime a dance-off introduction with finger guns (keep it silly).","points":10},{"text":"Say a clean punch dialogue you just invented.","points":10},{"text":"Cast yourself as the comic-relief sidekick and explain why.","points":10},{"text":"Do the ''interval popcorn'' mime.","points":10},{"text":"Name a film that always makes you smile.","points":10}]}'::jsonb
)
ON CONFLICT (game_key, theme_key, locale) DO UPDATE SET
  content = EXCLUDED.content,
  is_active = true,
  name = EXCLUDED.name,
  rules_text = EXCLUDED.rules_text;

INSERT INTO public.game_theme_packs (game_key, theme_key, locale, is_active, name, rules_text, content)
VALUES (
  'spin_dare', 'festival', 'en-IN', true,
  'Festival Challenge Wheel',
  'Spin for a festive, family-safe celebration dare. Skip allowance applies.',
  '{"tone":"festive","skip_allowance":1,"dares":[{"text":"Wish everyone using a festival greeting from any tradition.","points":10},{"text":"Teach one Holi-safe clap rhythm to the group.","points":10},{"text":"Mime lighting a diya carefully (no real fire).","points":10},{"text":"Share one childhood festival memory in 20 seconds.","points":10},{"text":"Demonstrate a tiny garba step, then invite one person to copy.","points":10},{"text":"Name three sweets you associate with celebrations.","points":10},{"text":"Lead a countdown as if fireworks are about to start.","points":10},{"text":"Describe your dream festive thali in five words.","points":10},{"text":"Do a gentle ''rangoli'' swirl gesture on the table air.","points":10},{"text":"Give a toast that starts with ''May this season…''.","points":10},{"text":"Act out flying a kite for 5 seconds.","points":10},{"text":"Name festivals in three different months.","points":10},{"text":"Hum a festive tune for 5 seconds (keep it short).","points":10},{"text":"Offer an imaginary box of mithai to two people.","points":10},{"text":"Explain how you''d decorate this room for Diwali in 15 seconds.","points":10},{"text":"Do a polite namaste to each person on your left.","points":10},{"text":"Share one gratitude line suitable for any holiday table.","points":10},{"text":"Mime wrapping a gift poorly, then fix it.","points":10},{"text":"Invent a new micro-festival name for this friend group.","points":10},{"text":"Lead a 5-second cheer for the hosts of tonight.","points":10},{"text":"Name two harvest festivals from India.","points":10},{"text":"Act out ''first rain of the season'' joyfully.","points":10},{"text":"Describe a festive outfit using only colors.","points":10},{"text":"Give everyone an imaginary ''shagun'' envelope (air high-five).","points":10},{"text":"End with a bilingual festival wish (any two languages you know).","points":10},{"text":"Invent a hashtag for tonight''s celebration.","points":10},{"text":"Share a festival food you could eat every week.","points":10},{"text":"Mime hanging a toran at the doorway.","points":10},{"text":"Wish the host using three different greeting styles.","points":10},{"text":"Lead a soft group clap that grows louder then stops.","points":10}]}'::jsonb
)
ON CONFLICT (game_key, theme_key, locale) DO UPDATE SET
  content = EXCLUDED.content,
  is_active = true,
  name = EXCLUDED.name,
  rules_text = EXCLUDED.rules_text;

UPDATE public.game_theme_packs
SET content = '{"tone":"classy","skip_allowance":1,"dares":[{"text":"Give a 15-second elevator pitch for a passion project.","points":10},{"text":"Compliment a peer''s leadership style with one specific example.","points":10},{"text":"Share one book, podcast, or course that helped you this year.","points":10},{"text":"Lead a 20-second networking intro: name, craft, one ask.","points":10},{"text":"Offer a ''warm intro'' between two people at the table.","points":10},{"text":"Name three strengths you bring to a team.","points":10},{"text":"Do a confident power-pose for 5 seconds, then smile.","points":10},{"text":"Pitch a mock product that solves a tiny everyday annoyance.","points":10},{"text":"Share a professional win from the last 90 days.","points":10},{"text":"Ask one thoughtful career question to someone here.","points":10},{"text":"Describe your ideal workday in exactly seven words.","points":10},{"text":"Give a shout-out to a mentor (no need for full name).","points":10},{"text":"Teach one productivity tip in under 15 seconds.","points":10},{"text":"Role-play declining a meeting politely but firmly.","points":10},{"text":"Celebrate someone else''s recent win with a toast.","points":10},{"text":"Name a skill you want to learn next quarter.","points":10},{"text":"Share a boundary you set that improved your week.","points":10},{"text":"Invent a team name for this table''s ''board of directors''.","points":10},{"text":"Offer one free advice coupon (verbal) to a friend.","points":10},{"text":"Describe your personal brand in three adjectives.","points":10},{"text":"Lead a 10-second round of applause for women supporting women.","points":10},{"text":"Share a non-work hobby that recharges you.","points":10},{"text":"Pitch a charity drive idea the group could do in a day.","points":10},{"text":"Name two people you''d put on an imaginary advisory board.","points":10},{"text":"Close with a one-line affirmation for the group.","points":10},{"text":"Share one lesson from a failure without naming employers.","points":10},{"text":"Recommend a tool or app that saves you time.","points":10},{"text":"Do a mock podcast intro for someone at the table.","points":10},{"text":"Name a cause you care about in one sentence.","points":10},{"text":"End with ''what''s one tiny next step?'' to the group.","points":10}]}'::jsonb,
    rules_text = 'Spin for a short confidence or networking challenge. No sensitive disclosures required.',
    name = 'Boss Ladies Challenge'
WHERE game_key = 'spin_dare' AND theme_key = 'women_business' AND locale = 'en-IN';


-- ---------------------------------------------------------------------------
-- 1. host_create_spin_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_create_spin_session(
  p_event_id uuid,
  p_theme_key text DEFAULT 'kitty',
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
  dares jsonb;
  skip_allowance integer;
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
    e.id, e.group_id, 'spin_dare', p_theme_key, 'manual', 'lobby', auth.uid(), cfg,
    8, 0
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
      'game_type', 'spin_dare',
      'theme_key', p_theme_key,
      'skip_allowance', skip_allowance,
      'dare_count', jsonb_array_length(dares)
    )
  );

  RETURN sid;
END;
$$;

COMMENT ON FUNCTION public.host_create_spin_session(uuid, text, jsonb) IS
  'Host: create Spin & Dare lobby, snapshot theme dares, seed game_players.';

REVOKE ALL ON FUNCTION public.host_create_spin_session(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_create_spin_session(uuid, text, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. join_spin_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_spin_session(p_session_id uuid)
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
  IF s.id IS NULL OR s.game_type <> 'spin_dare' THEN
    RAISE EXCEPTION 'Spin & Dare session not found';
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

REVOKE ALL ON FUNCTION public.join_spin_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_spin_session(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. host_spin_dare — server RNG dare + random joined player
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_spin_dare(p_session_id uuid)
RETURNS public.game_rounds
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s public.game_sessions;
  dares jsonb;
  used jsonb;
  available int[];
  pick_idx integer;
  dare jsonb;
  assignee uuid;
  r public.game_rounds;
  next_no integer;
  active_count integer;
BEGIN
  IF auth.uid() IS NULL AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = p_session_id FOR UPDATE;
  IF s.id IS NULL OR s.game_type <> 'spin_dare' THEN
    RAISE EXCEPTION 'Spin & Dare session not found';
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
    RAISE EXCEPTION 'Resolve the active dare before spinning again';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.game_players
    WHERE session_id = p_session_id AND status = 'joined'
  ) THEN
    RAISE EXCEPTION 'No joined players to assign a dare';
  END IF;

  dares := s.config->'dares';
  used := coalesce(s.config->'used_dare_indices', '[]'::jsonb);

  SELECT coalesce(array_agg(i ORDER BY i), ARRAY[]::int[])
  INTO available
  FROM generate_series(0, jsonb_array_length(dares) - 1) AS i
  WHERE NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements_text(used) u WHERE u::integer = i
  );

  -- Prefer unused; if deck exhausted, reshuffle (allow reuse)
  IF available IS NULL OR cardinality(available) = 0 THEN
    used := '[]'::jsonb;
    SELECT array_agg(i ORDER BY i) INTO available
    FROM generate_series(0, jsonb_array_length(dares) - 1) AS i;
  END IF;

  pick_idx := available[1 + floor(random() * cardinality(available))::integer];
  dare := dares->pick_idx;

  SELECT gp.user_id INTO assignee
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
      'text', dare->>'text',
      'points', coalesce((dare->>'points')::integer, 10),
      'dare_index', pick_idx,
      'assigned_user_id', assignee
    ),
    jsonb_build_object('assigned_user_id', assignee, 'dare_index', pick_idx),
    now(),
    NULL
  ) RETURNING * INTO r;

  used := used || jsonb_build_array(pick_idx);

  UPDATE public.game_sessions
  SET status = 'active',
      current_round = next_no,
      config = s.config || jsonb_build_object('used_dare_indices', used),
      started_at = coalesce(started_at, now()),
      updated_at = now()
  WHERE id = p_session_id;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    p_session_id, 'dare_spun', auth.uid(),
    jsonb_build_object(
      'round_id', r.id,
      'round_no', r.round_no,
      'dare_index', pick_idx,
      'text', dare->>'text',
      'assigned_user_id', assignee
    )
  );

  RETURN r;
END;
$$;

COMMENT ON FUNCTION public.host_spin_dare(uuid) IS
  'Host: RNG select an unused dare and a random joined player; opens an active round.';

REVOKE ALL ON FUNCTION public.host_spin_dare(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_spin_dare(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. resolve_spin_dare(round_id, status done|skip)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_spin_dare(
  p_round_id uuid,
  p_status text
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
  assignee uuid;
  skip_allowance integer;
  skips_used integer;
  pts integer;
  score integer := 0;
  v_action_type text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('done', 'skip') THEN
    RAISE EXCEPTION 'status must be done or skip';
  END IF;

  SELECT * INTO r FROM public.game_rounds WHERE id = p_round_id FOR UPDATE;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'Round not found';
  END IF;
  IF r.status <> 'active' THEN
    RAISE EXCEPTION 'Round is not active';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = r.session_id FOR UPDATE;
  IF s.id IS NULL OR s.game_type <> 'spin_dare' THEN
    RAISE EXCEPTION 'Spin & Dare session not found';
  END IF;
  IF s.status <> 'active' THEN
    RAISE EXCEPTION 'Session is not active';
  END IF;

  assignee := coalesce(
    (r.prompt->>'assigned_user_id')::uuid,
    (r.answer->>'assigned_user_id')::uuid
  );
  IF assignee IS NULL THEN
    RAISE EXCEPTION 'Round has no assigned player';
  END IF;

  -- Assignee or host may resolve
  IF auth.uid() IS DISTINCT FROM assignee
     AND NOT public.is_group_host(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Only the assigned player or host can resolve this dare';
  END IF;

  IF NOT public.is_group_member(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Group membership required';
  END IF;

  SELECT * INTO pl FROM public.game_players
  WHERE session_id = s.id AND user_id = assignee AND status = 'joined';
  IF pl.id IS NULL THEN
    RAISE EXCEPTION 'Assigned player is not joined';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.game_actions ga
    WHERE ga.round_id = p_round_id AND ga.action_type IN ('spin_done', 'spin_skip')
  ) THEN
    RAISE EXCEPTION 'Dare already resolved';
  END IF;

  pts := coalesce((r.prompt->>'points')::integer, 10);
  skip_allowance := coalesce((s.config->>'skip_allowance')::integer, 1);

  IF p_status = 'skip' THEN
    SELECT count(*)::integer INTO skips_used
    FROM public.game_actions ga
    WHERE ga.session_id = s.id
      AND ga.user_id = assignee
      AND ga.action_type = 'spin_skip';
    IF skips_used >= skip_allowance THEN
      RAISE EXCEPTION 'Skip allowance exhausted (% of %)', skips_used, skip_allowance;
    END IF;
    v_action_type := 'spin_skip';
    score := 0;
  ELSE
    v_action_type := 'spin_done';
    score := pts;
  END IF;

  INSERT INTO public.game_actions(
    session_id, round_id, user_id, action_type, payload, server_score
  ) VALUES (
    s.id, p_round_id, assignee, v_action_type,
    jsonb_build_object(
      'status', p_status,
      'resolved_by', auth.uid(),
      'assigned_user_id', assignee
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
        'resolution', p_status,
        'resolved_by', auth.uid(),
        'server_score', score
      )
  WHERE id = p_round_id;

  INSERT INTO public.game_events(session_id, event_type, actor_id, payload)
  VALUES (
    s.id, 'dare_resolved', auth.uid(),
    jsonb_build_object(
      'round_id', p_round_id,
      'status', p_status,
      'assigned_user_id', assignee,
      'server_score', score
    )
  );

  RETURN act;
END;
$$;

COMMENT ON FUNCTION public.resolve_spin_dare(uuid, text) IS
  'Assignee or host: mark dare done (score) or skip (0, enforces skip_allowance).';

REVOKE ALL ON FUNCTION public.resolve_spin_dare(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.resolve_spin_dare(uuid, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. host_end_spin_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_end_spin_session(p_session_id uuid)
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
  IF s.id IS NULL OR s.game_type <> 'spin_dare' THEN
    RAISE EXCEPTION 'Spin & Dare session not found';
  END IF;
  IF NOT public.is_group_host(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;
  IF s.status = 'completed' THEN
    RAISE EXCEPTION 'Session already completed';
  END IF;

  -- Cancel any unresolved active round
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

REVOKE ALL ON FUNCTION public.host_end_spin_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_end_spin_session(uuid)
  TO authenticated, service_role;
