-- ---------------------------------------------------------------------------
-- AP11: let the admin read every game session and everything inside it --
-- who played, what they answered, what they claimed, what they won.
--
-- READ ONLY. No admin write or void path for game data is added here -- a
-- completed game is history, not something an admin edits. Nothing in
-- this migration writes to game_sessions/game_players/game_rounds/
-- game_actions/game_claims/game_prizes/tambola_tickets.
--
-- Every column referenced below was verified against the actual table
-- definitions in supabase/migrations/20260801140136_remote_schema.sql
-- (plus the two later ALTERs to game_sessions:
-- 20260822120000_group_traditions_and_standalone_games.sql, which made
-- event_id nullable for standalone group games, and
-- 20260905010000_p39_tambola_session_label_map.sql, which added
-- number_label_map) -- not assumed. In particular: the game-kind column
-- is game_sessions.game_type (not game_key); game_claims is where a
-- winner is recorded (status='verified' rows, joined to game_prizes via
-- prize_id) -- game_prizes itself has no winner column.
--
-- Does NOT change any existing RLS policy. Every table this migration
-- reads from keeps exactly the member-scoped policies it already has; the
-- three RPCs below are SECURITY DEFINER and bypass RLS by the same
-- established mechanism as every other admin-surface RPC since AP2,
-- guarded by is_admin() -- following the AP7 pattern exactly.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. tambola_variants.default_tickets_per_player -- admin-editable content
--    the frontend reads as a default when distributing tickets. Does NOT
--    change host_distribute_tambola_tickets, which keeps taking
--    p_tickets_each as an explicit host-supplied parameter (1-6, same
--    range as this column's CHECK) -- this is additive content, not a
--    behaviour change to that function.
-- ---------------------------------------------------------------------------
ALTER TABLE public.tambola_variants
  ADD COLUMN IF NOT EXISTS default_tickets_per_player integer NOT NULL DEFAULT 1;

ALTER TABLE public.tambola_variants
  DROP CONSTRAINT IF EXISTS tambola_variants_default_tickets_per_player_check;
ALTER TABLE public.tambola_variants
  ADD CONSTRAINT tambola_variants_default_tickets_per_player_check
  CHECK (default_tickets_per_player BETWEEN 1 AND 6);

COMMENT ON COLUMN public.tambola_variants.default_tickets_per_player IS
  'Admin-editable default the frontend pre-fills when a host distributes tickets; host_distribute_tambola_tickets itself is unchanged and still takes an explicit p_tickets_each (1-6). Defaults to 1 for every existing variant.';

-- ---------------------------------------------------------------------------
-- 2a. admin_list_game_sessions(p_search, p_game_type, p_status, p_limit,
--     p_offset)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_game_sessions(
  p_search text DEFAULT NULL,
  p_game_type text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
) RETURNS TABLE (
  id uuid,
  game_type text,
  variant text,
  play_mode text,
  status text,
  group_name text,
  event_title text,
  host_name text,
  created_at timestamptz,
  started_at timestamptz,
  ended_at timestamptz,
  player_count bigint,
  ticket_count bigint,
  prize_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  RETURN QUERY
  SELECT
    s.id, s.game_type, s.variant, s.play_mode, s.status,
    g.name AS group_name,
    e.title AS event_title,
    h.name AS host_name,
    s.created_at, s.started_at, s.ended_at,
    (SELECT count(*) FROM public.game_players gp WHERE gp.session_id = s.id) AS player_count,
    (SELECT count(*) FROM public.tambola_tickets tt WHERE tt.session_id = s.id) AS ticket_count,
    (SELECT count(*) FROM public.game_prizes gpz WHERE gpz.session_id = s.id) AS prize_count
  FROM public.game_sessions s
  LEFT JOIN public.groups g ON g.id = s.group_id
  LEFT JOIN public.events e ON e.id = s.event_id
  LEFT JOIN public.users h ON h.id = s.host_id
  WHERE (p_search IS NULL OR g.name ILIKE '%' || p_search || '%' OR e.title ILIKE '%' || p_search || '%')
    AND (p_game_type IS NULL OR s.game_type = p_game_type)
    AND (p_status IS NULL OR s.status = p_status)
  ORDER BY s.created_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.admin_list_game_sessions(text, text, text, int, int) IS
  'Any active admin. Every game session (optionally filtered by group/event-title search, game_type, or status) with group/event/host names and player/ticket/prize counts. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_game_sessions(text, text, text, int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_list_game_sessions(text, text, text, int, int) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_game_sessions(text, text, text, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2b. admin_game_session_detail(p_session_id) -- the session plus players,
--     prizes (with verified winners from game_claims), rounds, and
--     tambola tickets where applicable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_game_session_detail(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  s public.game_sessions;
  result jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  SELECT * INTO s FROM public.game_sessions WHERE id = p_session_id;
  IF s.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  SELECT jsonb_build_object(
    'id', s.id,
    'game_id', s.game_id,
    'event_id', s.event_id,
    'event_title', (SELECT e.title FROM public.events e WHERE e.id = s.event_id),
    'group_id', s.group_id,
    'group_name', (SELECT g.name FROM public.groups g WHERE g.id = s.group_id),
    'game_type', s.game_type,
    'variant', s.variant,
    'play_mode', s.play_mode,
    'status', s.status,
    'host_id', s.host_id,
    'host_name', (SELECT h.name FROM public.users h WHERE h.id = s.host_id),
    'config', s.config,
    'current_round', s.current_round,
    'current_number', s.current_number,
    'called_numbers', s.called_numbers,
    'started_at', s.started_at,
    'ended_at', s.ended_at,
    'created_at', s.created_at,
    'players', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'user_id', gp.user_id,
          'user_name', pu.name,
          'status', gp.status,
          'score', gp.score,
          'joined_at', gp.joined_at
        )
        ORDER BY gp.joined_at
      )
      FROM public.game_players gp
      LEFT JOIN public.users pu ON pu.id = gp.user_id
      WHERE gp.session_id = s.id
    ), '[]'::jsonb),
    'prizes', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', gpz.id,
          'prize_type', gpz.prize_type,
          'display_name', gpz.display_name,
          'sort_order', gpz.sort_order,
          'total_slots', gpz.total_slots,
          'awarded_slots', gpz.awarded_slots,
          'is_closed', gpz.is_closed,
          'winners', coalesce((
            SELECT jsonb_agg(
              jsonb_build_object(
                'user_id', gc.user_id,
                'user_name', wu.name,
                'claimed_at', gc.claimed_at,
                'verified_at', gc.verified_at
              )
            )
            FROM public.game_claims gc
            LEFT JOIN public.users wu ON wu.id = gc.user_id
            WHERE gc.prize_id = gpz.id AND gc.status = 'verified'
          ), '[]'::jsonb)
        )
        ORDER BY gpz.sort_order
      )
      FROM public.game_prizes gpz
      WHERE gpz.session_id = s.id
    ), '[]'::jsonb),
    'rounds', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', gr.id,
          'round_no', gr.round_no,
          'status', gr.status,
          'prompt', gr.prompt,
          'answer', gr.answer,
          'started_at', gr.started_at,
          'ends_at', gr.ends_at,
          'completed_at', gr.completed_at
        )
        ORDER BY gr.round_no
      )
      FROM public.game_rounds gr
      WHERE gr.session_id = s.id
    ), '[]'::jsonb),
    'tambola_tickets', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', tt.id,
          'user_id', tt.user_id,
          'user_name', tu.name,
          'ticket_no', tt.ticket_no,
          'grid', tt.grid,
          'marked_numbers', tt.marked_numbers
        )
        ORDER BY tt.ticket_no
      )
      FROM public.tambola_tickets tt
      LEFT JOIN public.users tu ON tu.id = tt.user_id
      WHERE tt.session_id = s.id
    ), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$$;

COMMENT ON FUNCTION public.admin_game_session_detail(uuid) IS
  'Any active admin. One session''s full detail: players (with names), prizes (with verified winners from game_claims -- game_prizes itself has no winner column), rounds, and tambola_tickets (empty array for non-Tambola games). Errors: KITPAT_ADMIN_ONLY / KITPAT_NOT_FOUND.';

REVOKE ALL ON FUNCTION public.admin_game_session_detail(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_game_session_detail(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_game_session_detail(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2c. admin_list_game_answers(p_session_id, p_limit, p_offset) -- per-user
--     answers/actions (game_actions) and claims (game_claims) for a
--     session, newest first.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_game_answers(
  p_session_id uuid,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
) RETURNS TABLE (
  id text,
  kind text,
  user_id uuid,
  user_name text,
  round_no integer,
  label text,
  payload jsonb,
  outcome text,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  RETURN QUERY
  SELECT
    a.id::text, 'action'::text, a.user_id, u.name,
    r.round_no, a.action_type, a.payload,
    a.server_score::text, a.created_at
  FROM public.game_actions a
  LEFT JOIN public.users u ON u.id = a.user_id
  LEFT JOIN public.game_rounds r ON r.id = a.round_id
  WHERE a.session_id = p_session_id

  UNION ALL

  SELECT
    c.id::text, 'claim'::text, c.user_id, u.name,
    NULL::integer, p.display_name, c.verification_details,
    c.status, c.claimed_at
  FROM public.game_claims c
  LEFT JOIN public.users u ON u.id = c.user_id
  LEFT JOIN public.game_prizes p ON p.id = c.prize_id
  WHERE c.session_id = p_session_id

  ORDER BY created_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.admin_list_game_answers(uuid, int, int) IS
  'Any active admin. Every game_actions row (kind=action: what a player submitted, round_no, server_score as outcome) and game_claims row (kind=claim: which prize, verification_details, status as outcome) for a session, newest first, with the player''s name. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_game_answers(uuid, int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_list_game_answers(uuid, int, int) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_list_game_answers(uuid, int, int) TO authenticated, service_role;
