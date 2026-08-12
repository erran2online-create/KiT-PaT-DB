-- P18: Rapid Fire Circle — real gameplay RPCs on shared game_* tables.
-- Scoring (first-correct-wins, timed):
--   • submit after round.ends_at → server_score = 0 (late)
--   • answer not matching prompt.expected (case/space-insensitive) → 0
--   • first on-time correct response on the round → full points (prompt.points, default 10)
--   • later correct on-time responses → 0 (first-correct-wins)
--   • one submission per user per round (subsequent calls rejected)

-- ---------------------------------------------------------------------------
-- Seed theme packs with ≥20 prompts each (kitty, bollywood, festival)
-- ---------------------------------------------------------------------------
UPDATE public.game_theme_packs
SET content = jsonb_build_object(
  'tone', 'witty',
  'timer_seconds', 10,
  'prompts', jsonb_build_array(
    jsonb_build_object('text','What''s the most overused excuse in this kitty group?','expected',jsonb_build_array('traffic','meeting','forgot','work'),'points',10),
    jsonb_build_object('text','Who always ''forgets'' their contribution until the host chases?','expected',jsonb_build_array('me','host','everyone'),'points',10),
    jsonb_build_object('text','Name a snack that disappears first at every meet.','expected',jsonb_build_array('chips','samosa','pakora','namkeen','biscuits'),'points',10),
    jsonb_build_object('text','What time do meetings actually start vs the invite?','expected',jsonb_build_array('late','never on time','30 min late','fashionably late'),'points',10),
    jsonb_build_object('text','Best one-word review of last month''s kitty host.','expected',jsonb_build_array('legend','chaotic','generous','stressed','fun'),'points',10),
    jsonb_build_object('text','What''s banned from the next kitty dinner?','expected',jsonb_build_array('phones','politics','diet talk','work talk'),'points',10),
    jsonb_build_object('text','Who is most likely to start a payment UPI chaos thread?','expected',jsonb_build_array('host','treasurer','me'),'points',10),
    jsonb_build_object('text','Finish: ''I''ll pay tomorrow'' really means…','expected',jsonb_build_array('never','next month','after reminder','next kitty'),'points',10),
    jsonb_build_object('text','Pick the group''s unofficial mascot snack brand.','expected',jsonb_build_array('lays','haldiram','britannia','parle'),'points',10),
    jsonb_build_object('text','What''s the polite word for ''I forgot again''?','expected',jsonb_build_array('sorry','next time','busy','hectic'),'points',10),
    jsonb_build_object('text','Who takes the most photos and posts none?','expected',jsonb_build_array('me','everyone','photographer'),'points',10),
    jsonb_build_object('text','Name the chat that blows up right before a meet.','expected',jsonb_build_array('whatsapp','telegram','group chat'),'points',10),
    jsonb_build_object('text','What gift re-gift gets recycled every year?','expected',jsonb_build_array('candle','mug','frame','diary'),'points',10),
    jsonb_build_object('text','Best excuse for leaving early from kitty.','expected',jsonb_build_array('kids','work','traffic',' Relatives'),'points',10),
    jsonb_build_object('text','Who negotiates the hardest on the restaurant bill?','expected',jsonb_build_array('host','me','treasurer'),'points',10),
    jsonb_build_object('text','One word for the monthly contribution reminder tone.','expected',jsonb_build_array('polite','passive aggressive','urgent','sweet'),'points',10),
    jsonb_build_object('text','What always runs out of stock at the host''s place?','expected',jsonb_build_array('ice','plates','glasses','chairs'),'points',10),
    jsonb_build_object('text','Who arrives with ''I''m five minutes away'' for 40 minutes?','expected',jsonb_build_array('me','everyone','that one friend'),'points',10),
    jsonb_build_object('text','Name a topic that derails every serious kitty discussion.','expected',jsonb_build_array('food','gossip','movies','kids'),'points',10),
    jsonb_build_object('text','What should the winner of tonight''s game get?','expected',jsonb_build_array('treat','exemption','crown','bragging rights'),'points',10)
  )
)
WHERE game_key = 'rapid_fire' AND theme_key = 'kitty' AND locale = 'en-IN';

UPDATE public.game_theme_packs
SET content = jsonb_build_object(
  'tone', 'dramatic',
  'timer_seconds', 10,
  'prompts', jsonb_build_array(
    jsonb_build_object('text','Complete: ''Mere paas maa hai'' — from which classic?','expected',jsonb_build_array('deewaar','deewar'),'points',10),
    jsonb_build_object('text','Who said ''Kitne aadmi the?''','expected',jsonb_build_array('gabbar','gabbar singh'),'points',10),
    jsonb_build_object('text','Film: a man runs for a train with mustard fields vibe.','expected',jsonb_build_array('ddl j','ddlj','dilwale dulhania le jayenge'),'points',10),
    jsonb_build_object('text','Iconic dialogue: ''Pushpa, I hate tears''. Movie?','expected',jsonb_build_array('amar akbar anthony'),'points',10),
    jsonb_build_object('text','Name Shah Rukh''s ''Rahul'' film with a European train.','expected',jsonb_build_array('ddl j','ddlj','dilwale dulhania le jayenge'),'points',10),
    jsonb_build_object('text','Who plays Mogambo?','expected',jsonb_build_array('amrish puri'),'points',10),
    jsonb_build_object('text','Song cue: ''Tujhe dekha to ye jaana sanam'' — film?','expected',jsonb_build_array('ddl j','ddlj','dilwale dulhania le jayenge'),'points',10),
    jsonb_build_object('text','Villain who wants ''Don ko pakadna mushkil hi nahi…''','expected',jsonb_build_array('don'),'points',10),
    jsonb_build_object('text','Which film has the ''All izz well'' mantra?','expected',jsonb_build_array('3 idiots','three idiots'),'points',10),
    jsonb_build_object('text','Amitabh''s angry young man classic with coal mines?','expected',jsonb_build_array('deewaar','deewar'),'points',10),
    jsonb_build_object('text','Name the movie with ''Babu moshai''.','expected',jsonb_build_array('anand'),'points',10),
    jsonb_build_object('text','Who directed Lagaan?','expected',jsonb_build_array('ashutosh gowariker','ashutosh gowarikar'),'points',10),
    jsonb_build_object('text','Film: ''Recovering from a heartbreak? Try…'' viral SRK.','expected',jsonb_build_array('jab harry met sejal'),'points',10),
    jsonb_build_object('text','Complete: ''Picture abhi baaki hai…''','expected',jsonb_build_array('mere dost','picture abhi baaki hai mere dost'),'points',10),
    jsonb_build_object('text','Which film features ''Jai Ho''?','expected',jsonb_build_array('slumdog millionaire'),'points',10),
    jsonb_build_object('text','Hero of Sholay opposite Dharmendra.','expected',jsonb_build_array('amitabh','amitabh bachchan'),'points',10),
    jsonb_build_object('text','Name Rani Mukerji''s iconic black dress thriller.','expected',jsonb_build_array('black'),'points',10),
    jsonb_build_object('text','Film with the dialogue ''How''s the josh?''','expected',jsonb_build_array('uri','uri the surgical strike'),'points',10),
    jsonb_build_object('text','Who sang the original ''Chaiyya Chaiyya''?','expected',jsonb_build_array('sukhwinder','sukhwinder singh'),'points',10),
    jsonb_build_object('text','Kabhi Khushi Kabhie Gham family surname?','expected',jsonb_build_array('raichand'),'points',10)
  )
)
WHERE game_key = 'rapid_fire' AND theme_key = 'bollywood' AND locale = 'en-IN';

INSERT INTO public.game_theme_packs (game_key, theme_key, locale, is_active, name, rules_text, content)
VALUES (
  'rapid_fire',
  'festival',
  'en-IN',
  true,
  'Festival Rapid Fire',
  'Host advances prompts. First correct on-time answer scores; late answers score 0.',
  jsonb_build_object(
    'tone', 'festive',
    'timer_seconds', 10,
    'prompts', jsonb_build_array(
      jsonb_build_object('text','Colour most associated with Holi.','expected',jsonb_build_array('gulal','colours','all colours','rainbow'),'points',10),
      jsonb_build_object('text','Sweet most gifted at Diwali.','expected',jsonb_build_array('ladoo','laddu','barfi','mithai','gulab jamun'),'points',10),
      jsonb_build_object('text','What do you light on Diwali night?','expected',jsonb_build_array('diya','diyas','lamps','candles'),'points',10),
      jsonb_build_object('text','Festival of lights is…','expected',jsonb_build_array('diwali','deepavali'),'points',10),
      jsonb_build_object('text','What do siblings tie on Raksha Bandhan?','expected',jsonb_build_array('rakhi'),'points',10),
      jsonb_build_object('text','Eid greeting often said.','expected',jsonb_build_array('eid mubarak','mubarak'),'points',10),
      jsonb_build_object('text','Christmas tree topper classic.','expected',jsonb_build_array('star','angel'),'points',10),
      jsonb_build_object('text','Harvest festival of Punjab.','expected',jsonb_build_array('lohri','baisakhi'),'points',10),
      jsonb_build_object('text','On Janmashtami, kids break a…','expected',jsonb_build_array('matki','dahi handi','handi'),'points',10),
      jsonb_build_object('text','Navratri dance form.','expected',jsonb_build_array('garba','dandiya'),'points',10),
      jsonb_build_object('text','Pongal is mainly celebrated in…','expected',jsonb_build_array('tamil nadu','tamilnadu','south india'),'points',10),
      jsonb_build_object('text','Durga Puja is biggest in…','expected',jsonb_build_array('bengal','west bengal','kolkata'),'points',10),
      jsonb_build_object('text','What fruit is smashed at Onam feasts imagery?','expected',jsonb_build_array('banana','none','payasam'),'points',10),
      jsonb_build_object('text','New Year in Gujarat often aligns with…','expected',jsonb_build_array('diwali','bestu varas'),'points',10),
      jsonb_build_object('text','Colour of traditional bridal lehenga vibe.','expected',jsonb_build_array('red','maroon'),'points',10),
      jsonb_build_object('text','What do you burst (carefully) at Diwali?','expected',jsonb_build_array('crackers','fireworks','patakhe'),'points',10),
      jsonb_build_object('text','Karva Chauth is kept for…','expected',jsonb_build_array('spouse','husband','partner'),'points',10),
      jsonb_build_object('text','Ganesh Chaturthi visarjan goes to…','expected',jsonb_build_array('water','sea','river','lake'),'points',10),
      jsonb_build_object('text','Name the crescent celebration after Ramadan.','expected',jsonb_build_array('eid','eid ul fitr','eid-ul-fitr'),'points',10),
      jsonb_build_object('text','Makar Sankranti kite festival city fame.','expected',jsonb_build_array('ahmedabad','gujarat','jaipur'),'points',10)
    )
  )
)
ON CONFLICT (game_key, theme_key, locale) DO UPDATE SET
  content = EXCLUDED.content,
  is_active = true,
  name = coalesce(EXCLUDED.name, public.game_theme_packs.name);

-- Fix accidental space in kitty expected list from earlier draft if any
UPDATE public.game_theme_packs
SET content = jsonb_set(
  content,
  '{prompts}',
  (
    SELECT jsonb_agg(
      CASE
        WHEN p->>'text' LIKE 'Best excuse for leaving%' THEN
          jsonb_set(p, '{expected}', '["kids","work","traffic","relatives"]'::jsonb)
        ELSE p
      END
    )
    FROM jsonb_array_elements(content->'prompts') p
  )
)
WHERE game_key = 'rapid_fire' AND theme_key = 'kitty';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._rf_normalize_answer(p_raw text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(trim(regexp_replace(coalesce(p_raw, ''), '\s+', ' ', 'g')));
$$;

CREATE OR REPLACE FUNCTION public._rf_answer_matches(p_payload jsonb, p_expected jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  guess text := public._rf_normalize_answer(
    coalesce(p_payload->>'answer', p_payload->>'text', p_payload->>'response', p_payload::text)
  );
  exp text;
BEGIN
  IF p_expected IS NULL OR guess IS NULL OR guess = '' OR guess = 'null' THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(p_expected) = 'array' THEN
    FOR exp IN SELECT public._rf_normalize_answer(x) FROM jsonb_array_elements_text(p_expected) AS t(x)
    LOOP
      IF exp <> '' AND (guess = exp OR guess LIKE '%' || exp || '%' OR exp LIKE '%' || guess || '%') THEN
        RETURN true;
      END IF;
    END LOOP;
    RETURN false;
  END IF;
  exp := public._rf_normalize_answer(p_expected #>> '{}');
  IF exp = '' THEN
    exp := public._rf_normalize_answer(p_expected::text);
  END IF;
  RETURN exp <> '' AND (guess = exp OR guess LIKE '%' || exp || '%' OR exp LIKE '%' || guess || '%');
END;
$$;

-- ---------------------------------------------------------------------------
-- 1. host_create_rf_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_create_rf_session(
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
    e.id, e.group_id, 'rapid_fire', p_theme_key, 'manual', 'lobby', auth.uid(), cfg,
    timer_s, 0
  ) RETURNING id INTO sid;

  -- Seed all group members as invited; host joined
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
      'game_type', 'rapid_fire',
      'theme_key', p_theme_key,
      'timer_seconds', timer_s,
      'prompt_count', jsonb_array_length(prompts)
    )
  );

  RETURN sid;
END;
$$;

COMMENT ON FUNCTION public.host_create_rf_session(uuid, text, jsonb) IS
  'Host: create Rapid Fire lobby, snapshot theme prompts into session.config, seed game_players.';

REVOKE ALL ON FUNCTION public.host_create_rf_session(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_create_rf_session(uuid, text, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. join_rf_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_rf_session(p_session_id uuid)
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
  IF s.id IS NULL OR s.game_type <> 'rapid_fire' THEN
    RAISE EXCEPTION 'Rapid Fire session not found';
  END IF;
  IF s.status NOT IN ('lobby', 'active') THEN
    RAISE EXCEPTION 'Session is not joinable (%)' , s.status;
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

REVOKE ALL ON FUNCTION public.join_rf_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.join_rf_session(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. host_next_rf_prompt
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_next_rf_prompt(p_session_id uuid)
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
BEGIN
  IF auth.uid() IS NULL AND auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = p_session_id FOR UPDATE;
  IF s.id IS NULL OR s.game_type <> 'rapid_fire' THEN
    RAISE EXCEPTION 'Rapid Fire session not found';
  END IF;
  IF NOT public.is_group_host(s.group_id, auth.uid()) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;
  IF s.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'Session already ended';
  END IF;

  -- Complete any active round
  UPDATE public.game_rounds
  SET status = 'completed',
      completed_at = coalesce(completed_at, now())
  WHERE session_id = p_session_id AND status = 'active';

  prompts := s.config->'prompts';
  cursor := coalesce((s.config->>'prompt_cursor')::integer, 0);
  IF prompts IS NULL OR cursor >= jsonb_array_length(prompts) THEN
    RAISE EXCEPTION 'No more prompts in this session';
  END IF;

  prompt := prompts->cursor;
  timer_s := coalesce((s.config->>'timer_seconds')::integer, 10);
  next_no := cursor + 1;

  INSERT INTO public.game_rounds(
    session_id, round_no, status, prompt, answer, started_at, ends_at
  ) VALUES (
    p_session_id,
    next_no,
    'active',
    jsonb_build_object(
      'text', prompt->>'text',
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
      'text', prompt->>'text',
      'ends_at', r.ends_at
    )
  );

  RETURN r;
END;
$$;

REVOKE ALL ON FUNCTION public.host_next_rf_prompt(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_next_rf_prompt(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. submit_rf_response
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_rf_response(
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
  IF s.id IS NULL OR s.game_type <> 'rapid_fire' THEN
    RAISE EXCEPTION 'Rapid Fire session not found';
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
    WHERE round_id = p_round_id AND user_id = auth.uid() AND action_type = 'rf_response'
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
        AND action_type = 'rf_response'
        AND server_score > 0
    );
    IF first_win THEN
      score := pts;
    END IF;
  END IF;

  INSERT INTO public.game_actions(
    session_id, round_id, user_id, action_type, payload, server_score
  ) VALUES (
    s.id, p_round_id, auth.uid(), 'rf_response',
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

COMMENT ON FUNCTION public.submit_rf_response(uuid, jsonb) IS
  'Member: submit Rapid Fire answer. Late=0; wrong=0; first on-time correct gets points; others 0.';

REVOKE ALL ON FUNCTION public.submit_rf_response(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_rf_response(uuid, jsonb)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. host_end_rf_session
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_end_rf_session(p_session_id uuid)
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
  IF s.id IS NULL OR s.game_type <> 'rapid_fire' THEN
    RAISE EXCEPTION 'Rapid Fire session not found';
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

REVOKE ALL ON FUNCTION public.host_end_rf_session(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.host_end_rf_session(uuid)
  TO authenticated, service_role;
