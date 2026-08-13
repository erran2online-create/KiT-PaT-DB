-- P20: Emoji Guess gameplay (P18 Rapid Fire pattern).
-- Scoring: late=0, wrong=0, first on-time correct gets points; later correct=0.
-- Reuses public._rf_normalize_answer / public._rf_answer_matches.


UPDATE public.game_theme_packs
SET content = '{"tone":"dramatic","timer_seconds":20,"prompts":[{"emoji":"🚂❤️🇨🇭","text":"🚂❤️🇨🇭","expected":["ddlj","dilwale dulhania le jayenge"],"points":10},{"emoji":"🔫🚂🔥","text":"🔫🚂🔥","expected":["sholay"],"points":10},{"emoji":"🎓🤦‍♂️💊","text":"🎓🤦‍♂️💊","expected":["3 idiots","three idiots"],"points":10},{"emoji":"🏏🇬🇧🇮🇳","text":"🏏🇬🇧🇮🇳","expected":["lagaan"],"points":10},{"emoji":"🐯❤️🔫","text":"🐯❤️🔫","expected":["ek tha tiger"],"points":10},{"emoji":"🖤👗👑","text":"🖤👗👑","expected":["black"],"points":10},{"emoji":"💣🕶️","text":"💣🕶️","expected":["don"],"points":10},{"emoji":"👨‍👩‍👦🇨🇦","text":"👨‍👩‍👦🇨🇦","expected":["kabhi khushi kabhie gham","k3g"],"points":10},{"emoji":"⚽🇮🇳🏆","text":"⚽🇮🇳🏆","expected":["chak de india"],"points":10},{"emoji":"👻🛕😂","text":"👻🛕😂","expected":["bhool bhulaiyaa","bhool bhulaiya"],"points":10},{"emoji":"🦸🌃","text":"🦸🌃","expected":["krrish"],"points":10},{"emoji":"🙏😲🛕","text":"🙏😲🛕","expected":["oh my god","omg"],"points":10},{"emoji":"💃🕺🎉","text":"💃🕺🎉","expected":["yeh jawaani hai deewani","yjhd"],"points":10},{"emoji":"🚓🔫","text":"🚓🔫","expected":["singham"],"points":10},{"emoji":"🎸🚌","text":"🎸🚌","expected":["rockstar"],"points":10},{"emoji":"🧠❤️👩","text":"🧠❤️👩","expected":["dear zindagi"],"points":10},{"emoji":"🪖🏔️","text":"🪖🏔️","expected":["uri","uri the surgical strike"],"points":10},{"emoji":"🧕✈️","text":"🧕✈️","expected":["jab we met"],"points":10},{"emoji":"🏖️🏄","text":"🏖️🏄","expected":["zindagi na milegi dobara","znmd"],"points":10},{"emoji":"🧒📘","text":"🧒📘","expected":["taare zameen par","tare zameen par"],"points":10},{"emoji":"🌙⭐","text":"🌙⭐","expected":["kal ho naa ho","kal ho na ho"],"points":10},{"emoji":"🎤🔁❤️","text":"🎤🔁❤️","expected":["om shanti om"],"points":10},{"emoji":"👸🪞","text":"👸🪞","expected":["padmaavat","padmavati"],"points":10},{"emoji":"🚗💨😎","text":"🚗💨😎","expected":["dhoom"],"points":10},{"emoji":"🥊👩","text":"🥊👩","expected":["mary kom"],"points":10},{"emoji":"⚖️👨😂","text":"⚖️👨😂","expected":["jolly llb","jolly llb 2"],"points":10},{"emoji":"🐉🥋","text":"🐉🥋","expected":["chandni chowk to china"],"points":10},{"emoji":"👩‍🎤🌟","text":"👩‍🎤🌟","expected":["secret superstar"],"points":10},{"emoji":"🐄📰","text":"🐄📰","expected":["peepli live"],"points":10},{"emoji":"💍😢✈️","text":"💍😢✈️","expected":["kabhi alvida naa kehna","kank"],"points":10},{"emoji":"🤡🎪🤝","text":"🤡🎪🤝","expected":["andaz apna apna"],"points":10},{"emoji":"🐍💃","text":"🐍💃","expected":["nagina"],"points":10},{"emoji":"🪖🇮🇳🇵🇰","text":"🪖🇮🇳🇵🇰","expected":["border"],"points":10},{"emoji":"📻❤️🏙️","text":"📻❤️🏙️","expected":["rock on","rock on!!"],"points":10}]}'::jsonb,
    rules_text = 'Guess the movie/title from emojis before the timer. First correct on-time answer scores.'
WHERE game_key = 'emoji_guess' AND theme_key = 'bollywood' AND locale = 'en-IN';

UPDATE public.game_theme_packs
SET content = '{"tone":"festive","timer_seconds":20,"prompts":[{"emoji":"🪔✨🏠","text":"🪔✨🏠","expected":["diwali","deepavali"],"points":10},{"emoji":"🎨💦👥","text":"🎨💦👥","expected":["holi"],"points":10},{"emoji":"🧵🤲❤️","text":"🧵🤲❤️","expected":["rakhi","raksha bandhan"],"points":10},{"emoji":"🌙🕌🍬","text":"🌙🕌🍬","expected":["eid","eid mubarak"],"points":10},{"emoji":"🎄🎁⭐","text":"🎄🎁⭐","expected":["christmas"],"points":10},{"emoji":"🪁☀️","text":"🪁☀️","expected":["makar sankranti","sankranti","uttarayan"],"points":10},{"emoji":"💃🟠","text":"💃🟠","expected":["garba","navratri","dandiya"],"points":10},{"emoji":"🐘🛕🎉","text":"🐘🛕🎉","expected":["ganesh chaturthi","ganesha chaturthi","ganesh"],"points":10},{"emoji":"🏹🔥😈","text":"🏹🔥😈","expected":["dussehra","vijayadashami"],"points":10},{"emoji":"🍚🥛☀️","text":"🍚🥛☀️","expected":["pongal"],"points":10},{"emoji":"🌺🗡️","text":"🌺🗡️","expected":["durga puja","durga"],"points":10},{"emoji":"🍌🍃🍽️","text":"🍌🍃🍽️","expected":["onam"],"points":10},{"emoji":"🔥🌽","text":"🔥🌽","expected":["lohri"],"points":10},{"emoji":"🌕🍵","text":"🌕🍵","expected":["karva chauth"],"points":10},{"emoji":"🥂1️⃣2️⃣3️⃣1️⃣","text":"🥂1️⃣2️⃣3️⃣1️⃣","expected":["new year","new years eve"],"points":10},{"emoji":"👰🤵","text":"👰🤵","expected":["wedding","shaadi","marriage"],"points":10},{"emoji":"🧧🐉","text":"🧧🐉","expected":["chinese new year","lunar new year"],"points":10},{"emoji":"🎃👻","text":"🎃👻","expected":["halloween"],"points":10},{"emoji":"🦃🍽️","text":"🦃🍽️","expected":["thanksgiving"],"points":10},{"emoji":"💝💘","text":"💝💘","expected":["valentine","valentines day","valentine''s day"],"points":10},{"emoji":"📚✏️🎒","text":"📚✏️🎒","expected":["teachers day","teacher''s day"],"points":10},{"emoji":"🇮🇳📜","text":"🇮🇳📜","expected":["republic day"],"points":10},{"emoji":"🕯️✡️","text":"🕯️✡️","expected":["hanukkah","chanukah"],"points":10},{"emoji":"🐑🕌","text":"🐑🕌","expected":["bakrid","eid ul adha","bakri eid"],"points":10},{"emoji":"🧠💡","text":"🧠💡","expected":["guru nanak jayanti","gurpurab"],"points":10},{"emoji":"🌙⭐🕌","text":"🌙⭐🕌","expected":["ramadan","ramzan"],"points":10},{"emoji":"🎭🎪","text":"🎭🎪","expected":["carnival","mela"],"points":10},{"emoji":"🌸💕","text":"🌸💕","expected":["basant","vasant panchami"],"points":10},{"emoji":"🛕🔔","text":"🛕🔔","expected":["temple festival","jatra"],"points":10},{"emoji":"🍇🍷","text":"🍇🍷","expected":["harvest festival","harvest"],"points":10},{"emoji":"🎅🦌","text":"🎅🦌","expected":["santa","christmas eve"],"points":10},{"emoji":"🧨🎆","text":"🧨🎆","expected":["fireworks","crackers"],"points":10},{"emoji":"🍬📦","text":"🍬📦","expected":["mithai","sweets"],"points":10},{"emoji":"🕯️🙏","text":"🕯️🙏","expected":["diya","lamp"],"points":10},{"emoji":"🇮🇳🎆8️⃣1️⃣5️⃣","text":"🇮🇳🎆8️⃣1️⃣5️⃣","expected":["independence day","15 august"],"points":10}]}'::jsonb,
    rules_text = 'Guess the festival or occasion from emojis before the timer. First correct on-time answer scores.'
WHERE game_key = 'emoji_guess' AND theme_key = 'festival' AND locale = 'en-IN';

INSERT INTO public.game_theme_packs (game_key, theme_key, locale, is_active, name, rules_text, content)
VALUES (
  'emoji_guess', 'kitty', 'en-IN', true,
  'Kitty Emoji Guess',
  'Guess the kitty-party phrase from emojis before the timer. First correct on-time answer scores.',
  '{"tone":"witty","timer_seconds":20,"prompts":[{"emoji":"💸📱😵","text":"💸📱😵","expected":["upi","payment","pay"],"points":10},{"emoji":"🍰☕💬","text":"🍰☕💬","expected":["gossip","chai pe charcha"],"points":10},{"emoji":"⏰🐢🚪","text":"⏰🐢🚪","expected":["late","fashionably late"],"points":10},{"emoji":"🍫📦🎁","text":"🍫📦🎁","expected":["return gift","return gifts"],"points":10},{"emoji":"📸🙈📱","text":"📸🙈📱","expected":["photos","no photos"],"points":10},{"emoji":"🧾🤯➗","text":"🧾🤯➗","expected":["bill","split bill"],"points":10},{"emoji":"🍿🎬🛋️","text":"🍿🎬🛋️","expected":["movie night"],"points":10},{"emoji":"🧺💰📅","text":"🧺💰📅","expected":["kitty","kitty party"],"points":10},{"emoji":"🎂👑🏠","text":"🎂👑🏠","expected":["host","hosting"],"points":10},{"emoji":"🥗❌🍕","text":"🥗❌🍕","expected":["diet fail","cheat day"],"points":10},{"emoji":"📞🔁😤","text":"📞🔁😤","expected":["reminder","follow up"],"points":10},{"emoji":"🍪🫖👯","text":"🍪🫖👯","expected":["brunch"],"points":10},{"emoji":"👗🪞✨","text":"👗🪞✨","expected":["outfit","dress code"],"points":10},{"emoji":"🚗📍❓","text":"🚗📍❓","expected":["location","where"],"points":10},{"emoji":"🎁🔁📦","text":"🎁🔁📦","expected":["regift","re-gift"],"points":10},{"emoji":"🧊🍹🥳","text":"🧊🍹🥳","expected":["party"],"points":10},{"emoji":"🤫🗣️👂","text":"🤫🗣️👂","expected":["secret","secrets"],"points":10},{"emoji":"🏆🥇🎉","text":"🏆🥇🎉","expected":["winner"],"points":10},{"emoji":"😴💤🏠","text":"😴💤🏠","expected":["early exit","leave early"],"points":10},{"emoji":"🛒🛍️💸","text":"🛒🛍️💸","expected":["shopping"],"points":10},{"emoji":"🧘‍♀️☕😌","text":"🧘‍♀️☕😌","expected":["self care","me time"],"points":10},{"emoji":"👶🍼🚫","text":"👶🍼🚫","expected":["kids free","no kids"],"points":10},{"emoji":"🌶️🔥🍲","text":"🌶️🔥🍲","expected":["spicy food","spicy"],"points":10},{"emoji":"🧹🏠✨","text":"🧹🏠✨","expected":["clean up","cleanup"],"points":10},{"emoji":"📣📅✅","text":"📣📅✅","expected":["rsvp"],"points":10},{"emoji":"🎲🃏😂","text":"🎲🃏😂","expected":["games","game night"],"points":10},{"emoji":"🥂🍾🎊","text":"🥂🍾🎊","expected":["celebration"],"points":10},{"emoji":"🤝💜👥","text":"🤝💜👥","expected":["friendship","friends"],"points":10},{"emoji":"📦🚚🏠","text":"📦🚚🏠","expected":["potluck"],"points":10},{"emoji":"🌧️☔🏠","text":"🌧️☔🏠","expected":["rain check","raincheck"],"points":10},{"emoji":"🧁📌📋","text":"🧁📌📋","expected":["menu"],"points":10},{"emoji":"🚕⏱️","text":"🚕⏱️","expected":["cab","ola","uber"],"points":10},{"emoji":"🧾✍️✅","text":"🧾✍️✅","expected":["accounts","settlement"],"points":10},{"emoji":"🎤🎶🥳","text":"🎤🎶🥳","expected":["karaoke"],"points":10}]}'::jsonb
)
ON CONFLICT (game_key, theme_key, locale) DO UPDATE SET
  content = EXCLUDED.content,
  is_active = true,
  name = EXCLUDED.name,
  rules_text = EXCLUDED.rules_text;


-- ---------------------------------------------------------------------------
-- 1. host_create_eg_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_create_eg_session(
  p_event_id uuid,
  p_theme_key text DEFAULT 'bollywood',
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
  timer_s integer;
  prompts jsonb;
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
    e.id, e.group_id, 'emoji_guess', p_theme_key, 'manual', 'lobby', auth.uid(), cfg,
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
      'game_type', 'emoji_guess',
      'theme_key', p_theme_key,
      'timer_seconds', timer_s,
      'prompt_count', jsonb_array_length(prompts)
    )
  );

  RETURN sid;
END;
$$;

COMMENT ON FUNCTION public.host_create_eg_session(uuid, text, jsonb) IS
  'Host: create Emoji Guess lobby, snapshot theme emoji prompts, seed game_players.';

REVOKE ALL ON FUNCTION public.host_create_eg_session(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_create_eg_session(uuid, text, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. join_eg_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_eg_session(p_session_id uuid)
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
  IF s.id IS NULL OR s.game_type <> 'emoji_guess' THEN
    RAISE EXCEPTION 'Emoji Guess session not found';
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

REVOKE ALL ON FUNCTION public.join_eg_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_eg_session(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. host_next_eg_prompt
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_next_eg_prompt(p_session_id uuid)
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
  timer_s integer;
  r public.game_rounds;
  next_no integer;
  emoji_text text;
BEGIN
  IF auth.uid() IS NULL AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = p_session_id FOR UPDATE;
  IF s.id IS NULL OR s.game_type <> 'emoji_guess' THEN
    RAISE EXCEPTION 'Emoji Guess session not found';
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
  cursor := coalesce((s.config->>'prompt_cursor')::integer, 0);
  IF prompts IS NULL OR cursor >= jsonb_array_length(prompts) THEN
    RAISE EXCEPTION 'No more emoji prompts in this session';
  END IF;

  prompt := prompts->cursor;
  timer_s := coalesce((s.config->>'timer_seconds')::integer, 20);
  next_no := cursor + 1;
  emoji_text := coalesce(prompt->>'emoji', prompt->>'text');

  INSERT INTO public.game_rounds(
    session_id, round_no, status, prompt, answer, started_at, ends_at
  ) VALUES (
    p_session_id,
    next_no,
    'active',
    jsonb_build_object(
      'emoji', emoji_text,
      'text', emoji_text,
      'points', coalesce((prompt->>'points')::integer, 10),
      'index', cursor
    ),
    jsonb_build_object('expected', prompt->'expected'),
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
      'emoji', emoji_text,
      'ends_at', r.ends_at
    )
  );

  RETURN r;
END;
$$;

REVOKE ALL ON FUNCTION public.host_next_eg_prompt(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_next_eg_prompt(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. submit_eg_response
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_eg_response(
  p_round_id uuid,
  p_payload jsonb
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
  correct boolean;
  first_win boolean;
  pts integer;
  score integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'payload must be a JSON object with answer';
  END IF;

  SELECT * INTO r FROM public.game_rounds WHERE id = p_round_id FOR UPDATE;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'Round not found';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = r.session_id FOR UPDATE;
  IF s.id IS NULL OR s.game_type <> 'emoji_guess' THEN
    RAISE EXCEPTION 'Emoji Guess session not found';
  END IF;
  IF s.status <> 'active' THEN
    RAISE EXCEPTION 'Session is not active';
  END IF;
  IF r.status <> 'active' THEN
    RAISE EXCEPTION 'Round is not active';
  END IF;
  IF NOT public.is_group_member(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Group membership required';
  END IF;

  SELECT * INTO pl FROM public.game_players
  WHERE session_id = s.id AND user_id = auth.uid() AND status = 'joined';
  IF pl.id IS NULL THEN
    RAISE EXCEPTION 'Join the session before submitting';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.game_actions
    WHERE round_id = p_round_id AND user_id = auth.uid() AND action_type = 'eg_response'
  ) THEN
    RAISE EXCEPTION 'Already submitted for this round';
  END IF;

  late := (r.ends_at IS NOT NULL AND now() > r.ends_at);
  correct := public._rf_answer_matches(p_payload, r.answer->'expected');
  pts := coalesce((r.prompt->>'points')::integer, 10);

  first_win := false;
  IF correct AND NOT late THEN
    first_win := NOT EXISTS (
      SELECT 1 FROM public.game_actions
      WHERE round_id = p_round_id
        AND action_type = 'eg_response'
        AND server_score > 0
    );
    IF first_win THEN
      score := pts;
    END IF;
  END IF;

  INSERT INTO public.game_actions(
    session_id, round_id, user_id, action_type, payload, server_score
  ) VALUES (
    s.id, p_round_id, auth.uid(), 'eg_response',
    p_payload || jsonb_build_object(
      'late', late,
      'correct', correct,
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
      'correct', correct,
      'first_correct', first_win
    )
  );

  RETURN act;
END;
$$;

COMMENT ON FUNCTION public.submit_eg_response(uuid, jsonb) IS
  'Member: submit Emoji Guess answer. Late=0; wrong=0; first on-time correct gets points.';

REVOKE ALL ON FUNCTION public.submit_eg_response(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_eg_response(uuid, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. host_end_eg_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_end_eg_session(p_session_id uuid)
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
  IF s.id IS NULL OR s.game_type <> 'emoji_guess' THEN
    RAISE EXCEPTION 'Emoji Guess session not found';
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

REVOKE ALL ON FUNCTION public.host_end_eg_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_end_eg_session(uuid)
  TO authenticated, service_role;
