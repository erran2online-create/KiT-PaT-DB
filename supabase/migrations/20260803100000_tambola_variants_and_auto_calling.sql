-- Tambola N-variant config + prize_config object wiring + automatic draw scheduler.
-- Does NOT modify claim_tambola_prize, host_check_tambola_claim, host_call_tambola_number,
-- or mark_tambola_number (engine already correct).

-- ---------------------------------------------------------------------------
-- 1. Columns already present: game_sessions.variant, game_sessions.play_mode
--    (play_mode is the stored 'manual'|'automatic' mode column).
--    Ensure comments reflect N-variant extensibility.
-- ---------------------------------------------------------------------------
COMMENT ON COLUMN public.game_sessions.variant IS
  'Tambola variant key from public.tambola_variants (classic, quick_10, bollywood, kitty_special, …). Schema supports N variants via that registry — do not hardcode a closed enum here.';

COMMENT ON COLUMN public.game_sessions.play_mode IS
  'manual: host calls host_call_tambola_number. automatic: server draws via process_due_tambola_auto_draws / pg_cron.';

-- ---------------------------------------------------------------------------
-- 2. N-variant registry (5th theme slot = insert a new active row later)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tambola_variants (
  key text PRIMARY KEY,
  display_name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 100,
  default_interval_seconds integer NOT NULL DEFAULT 8
    CHECK (default_interval_seconds BETWEEN 3 AND 60),
  default_prizes jsonb NOT NULL DEFAULT '["early_five","top_line","middle_line","bottom_line","corners","full_house"]'::jsonb,
  config jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.tambola_variants IS
  'Active Tambola variant keys allowed by host_create_tambola_session. Add rows to introduce new variants without code changes.';

INSERT INTO public.tambola_variants (key, display_name, is_active, sort_order, default_interval_seconds, default_prizes, config)
VALUES
  ('classic', 'Classic', true, 1, 8,
   '["early_five","top_line","middle_line","bottom_line","corners","full_house"]'::jsonb, '{}'::jsonb),
  ('quick_10', 'Quick 10-Minute', true, 2, 5,
   '["early_five","top_line","full_house"]'::jsonb, '{"target_minutes":10}'::jsonb),
  ('bollywood', 'Bollywood', true, 3, 8,
   '["early_five","top_line","middle_line","bottom_line","corners","full_house"]'::jsonb, '{}'::jsonb),
  ('kitty_special', 'Kitty Special', true, 4, 8,
   '["early_five","top_line","middle_line","bottom_line","corners","full_house"]'::jsonb, '{}'::jsonb)
ON CONFLICT (key) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  is_active = EXCLUDED.is_active,
  sort_order = EXCLUDED.sort_order,
  default_interval_seconds = EXCLUDED.default_interval_seconds,
  default_prizes = EXCLUDED.default_prizes,
  config = EXCLUDED.config;

ALTER TABLE public.tambola_variants ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "authenticated read active tambola variants" ON public.tambola_variants;
CREATE POLICY "authenticated read active tambola variants"
  ON public.tambola_variants FOR SELECT TO authenticated
  USING (is_active = true);

GRANT SELECT ON public.tambola_variants TO authenticated;
GRANT ALL ON public.tambola_variants TO service_role;

-- ---------------------------------------------------------------------------
-- 3. host_create_tambola_session — N-variant validation + object prize_config
--    Signature (same types as before): (event_id, variant, mode, prize_config)
--    prize_config supports:
--      {"early_five":4,"top_line":2,"full_house":3}          -- preferred
--      [{"type":"early_five","slots":4}, ...]               -- legacy array
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.host_create_tambola_session(uuid, text, text, jsonb);

CREATE OR REPLACE FUNCTION public.host_create_tambola_session(
  p_event_id uuid,
  p_variant text DEFAULT 'classic',
  p_mode text DEFAULT 'manual',
  p_prize_config jsonb DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  e public.events;
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

  select * into e from public.events where id = p_event_id;
  if e.id is null or not public.is_group_host(e.group_id, auth.uid()) then
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
    e.id, e.group_id, 'tambola', p_variant, p_mode, 'lobby', auth.uid(),
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
    jsonb_build_object('variant', p_variant, 'play_mode', p_mode, 'prize_count', sort_i)
  );

  return sid;
end;
$$;

REVOKE ALL ON FUNCTION public.host_create_tambola_session(uuid, text, text, jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.host_create_tambola_session(uuid, text, text, jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.host_create_tambola_session(uuid, text, text, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. host_distribute_tambola_tickets — add target 'all'|'selected' overload
--    Keep legacy (session_id, user_ids, tickets_each) as compatibility wrapper.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_distribute_tambola_tickets(
  p_session_id uuid,
  p_target text,
  p_user_ids uuid[] DEFAULT NULL,
  p_tickets_per_player integer DEFAULT 1
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  s public.game_sessions;
  uid uuid;
  ticket_no integer;
  made integer := 0;
  i integer;
  targets uuid[];
begin
  select * into s from public.game_sessions where id = p_session_id for update;
  if s.id is null or s.game_type <> 'tambola' or not public.is_group_host(s.group_id, auth.uid()) then
    raise exception 'Host access required';
  end if;
  if s.status <> 'lobby' then
    raise exception 'Tickets can only be distributed in lobby';
  end if;
  if p_tickets_per_player < 1 or p_tickets_per_player > 6 then
    raise exception 'Tickets per player must be 1-6';
  end if;
  if p_target is null or p_target not in ('all', 'selected') then
    raise exception 'target must be all or selected';
  end if;

  if p_target = 'all' then
    select array_agg(user_id) into targets from public.members where group_id = s.group_id;
  else
    if p_user_ids is null or cardinality(p_user_ids) = 0 then
      raise exception 'user_ids required when target is selected';
    end if;
    targets := p_user_ids;
  end if;

  select coalesce(max(t.ticket_no), 0) into ticket_no
  from public.tambola_tickets t where t.session_id = p_session_id;

  foreach uid in array coalesce(targets, array[]::uuid[]) loop
    if not public.is_group_member(s.group_id, uid) then
      raise exception 'Selected user is not a group member';
    end if;
    insert into public.game_players(session_id, user_id, status)
    values (p_session_id, uid, 'joined')
    on conflict (session_id, user_id) do update set status = 'joined';
    for i in 1..p_tickets_per_player loop
      ticket_no := ticket_no + 1;
      insert into public.tambola_tickets(session_id, user_id, ticket_no, grid)
      values (p_session_id, uid, ticket_no, public.generate_tambola_grid());
      made := made + 1;
    end loop;
  end loop;

  insert into public.game_events(session_id, event_type, actor_id, payload)
  values (
    p_session_id, 'tickets_distributed', auth.uid(),
    jsonb_build_object('count', made, 'target', p_target, 'tickets_per_player', p_tickets_per_player)
  );
  return made;
end;
$$;

-- Legacy signature → delegates to target-aware overload
CREATE OR REPLACE FUNCTION public.host_distribute_tambola_tickets(
  p_session_id uuid,
  p_user_ids uuid[] DEFAULT NULL,
  p_tickets_each integer DEFAULT 1
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
begin
  return public.host_distribute_tambola_tickets(
    p_session_id,
    case when p_user_ids is null then 'all' else 'selected' end,
    p_user_ids,
    p_tickets_each
  );
end;
$$;

REVOKE ALL ON FUNCTION public.host_distribute_tambola_tickets(uuid, text, uuid[], integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.host_distribute_tambola_tickets(uuid, text, uuid[], integer) TO authenticated;
GRANT ALL ON FUNCTION public.host_distribute_tambola_tickets(uuid, text, uuid[], integer) TO service_role;
REVOKE ALL ON FUNCTION public.host_distribute_tambola_tickets(uuid, uuid[], integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.host_distribute_tambola_tickets(uuid, uuid[], integer) TO authenticated;
GRANT ALL ON FUNCTION public.host_distribute_tambola_tickets(uuid, uuid[], integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Automatic calling worker + host_start_auto_calling
--    Reuses host_call_tambola_number (does not fork draw logic).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.process_due_tambola_auto_draws()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  r record;
  drew integer := 0;
  catchup integer;
  n integer;
begin
  for r in
    select id, host_id, draw_interval_seconds, next_auto_draw_at, called_numbers
    from public.game_sessions
    where game_type = 'tambola'
      and play_mode = 'automatic'
      and status = 'active'
      and next_auto_draw_at is not null
      and next_auto_draw_at <= now()
      and cardinality(called_numbers) < 90
    order by next_auto_draw_at
    for update skip locked
    limit 50
  loop
    -- Impersonate session host so existing host_call auth check passes
    perform set_config('request.jwt.claim.sub', r.host_id::text, true);

    -- Catch up at most a few draws if the scheduler lagged
    catchup := 0;
    while catchup < 5
      and exists (
        select 1 from public.game_sessions s
        where s.id = r.id
          and s.status = 'active'
          and s.play_mode = 'automatic'
          and s.next_auto_draw_at is not null
          and s.next_auto_draw_at <= now()
          and cardinality(s.called_numbers) < 90
      )
    loop
      begin
        n := public.host_call_tambola_number(r.id, null);
        drew := drew + 1;
        catchup := catchup + 1;
      exception when others then
        raise warning 'tambola auto-draw failed for session %: %', r.id, sqlerrm;
        exit;
      end;
    end loop;
  end loop;

  return drew;
end;
$$;

REVOKE ALL ON FUNCTION public.process_due_tambola_auto_draws() FROM PUBLIC;
GRANT ALL ON FUNCTION public.process_due_tambola_auto_draws() TO service_role;

CREATE OR REPLACE FUNCTION public.host_start_auto_calling(
  p_session_id uuid,
  p_interval_seconds integer DEFAULT NULL
) RETURNS public.game_sessions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  s public.game_sessions;
  interval_s integer;
begin
  select * into s from public.game_sessions where id = p_session_id for update;
  if s.id is null or s.game_type <> 'tambola' then
    raise exception 'Tambola session not found';
  end if;
  if not public.is_group_host(s.group_id, auth.uid()) then
    raise exception 'Host access required';
  end if;
  if s.play_mode <> 'automatic' then
    raise exception 'host_start_auto_calling is only valid for automatic mode sessions';
  end if;

  interval_s := coalesce(p_interval_seconds, s.draw_interval_seconds, 8);
  if interval_s < 3 or interval_s > 60 then
    raise exception 'interval_seconds must be between 3 and 60';
  end if;

  if s.status = 'lobby' then
    -- Arm interval now; calling begins when host_start_tambola sets status=active
    update public.game_sessions
    set draw_interval_seconds = interval_s,
        updated_at = now()
    where id = p_session_id
    returning * into s;
  elsif s.status in ('active', 'paused') then
    update public.game_sessions
    set draw_interval_seconds = interval_s,
        status = 'active',
        next_auto_draw_at = now(),
        started_at = coalesce(started_at, now()),
        updated_at = now()
    where id = p_session_id
    returning * into s;
  else
    raise exception 'Session cannot start auto-calling from status %', s.status;
  end if;

  insert into public.game_events(session_id, event_type, actor_id, payload)
  values (
    p_session_id, 'auto_calling_armed', auth.uid(),
    jsonb_build_object('interval_seconds', interval_s, 'status', s.status)
  );

  return s;
end;
$$;

REVOKE ALL ON FUNCTION public.host_start_auto_calling(uuid, integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.host_start_auto_calling(uuid, integer) TO authenticated;
GRANT ALL ON FUNCTION public.host_start_auto_calling(uuid, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. pg_cron schedule — every 5 seconds, no-op for manual sessions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;

DO $$
declare
  existing bigint;
begin
  select j.jobid into existing
  from cron.job j
  where j.jobname = 'tambola-auto-draws'
  limit 1;

  if existing is not null then
    perform cron.unschedule(existing);
  end if;

  perform cron.schedule(
    'tambola-auto-draws',
    '5 seconds',
    $cron$SELECT public.process_due_tambola_auto_draws();$cron$
  );
exception when others then
  -- Fallback if interval syntax unsupported: every minute with catch-up loop above
  begin
    perform cron.schedule(
      'tambola-auto-draws',
      '* * * * *',
      $cron$SELECT public.process_due_tambola_auto_draws();$cron$
    );
  exception when others then
    raise warning 'Could not schedule tambola-auto-draws cron job: %', sqlerrm;
  end;
end;
$$;
