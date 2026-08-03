-- Prompt 3: celebration Realtime broadcasts + enriched session event payloads.
-- game_events already exists with (session_id, event_type, actor_id, payload, created_at)
-- — do NOT create a duplicate session_events table; expose a compatibility view instead.
-- Does NOT change claim_tambola_prize or mark_tambola_number.
-- host_call_tambola_number / host_check_tambola_claim: validation/locking/pattern
-- lines stay byte-identical; only success-path insert/broadcast additions change.

-- ---------------------------------------------------------------------------
-- Compatibility view for Memory Card consumers expecting "session_events"
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.session_events AS
SELECT id, session_id, event_type, actor_id, payload, created_at
FROM public.game_events;

COMMENT ON VIEW public.session_events IS
  'Alias of game_events — authoritative call/claim/verdict log for Memory Cards.';

GRANT SELECT ON public.session_events TO authenticated;
GRANT SELECT ON public.session_events TO service_role;

-- ---------------------------------------------------------------------------
-- Pattern cell helpers (animation / so-close copy) — pure, no auth side effects
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tambola_pattern_required_numbers(
  p_grid jsonb,
  p_pattern text
) RETURNS integer[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  topv integer[]; midv integer[]; botv integer[]; allv integer[];
begin
  select array_agg((v#>>'{}')::integer) into topv
  from jsonb_array_elements(p_grid->0) v where v <> 'null'::jsonb;
  select array_agg((v#>>'{}')::integer) into midv
  from jsonb_array_elements(p_grid->1) v where v <> 'null'::jsonb;
  select array_agg((v#>>'{}')::integer) into botv
  from jsonb_array_elements(p_grid->2) v where v <> 'null'::jsonb;
  allv := coalesce(topv, array[]::integer[])
       || coalesce(midv, array[]::integer[])
       || coalesce(botv, array[]::integer[]);

  if p_pattern in ('early_five', 'early5') then
    return allv;
  elsif p_pattern = 'top_line' then
    return coalesce(topv, array[]::integer[]);
  elsif p_pattern = 'middle_line' then
    return coalesce(midv, array[]::integer[]);
  elsif p_pattern = 'bottom_line' then
    return coalesce(botv, array[]::integer[]);
  elsif p_pattern = 'full_house' then
    return allv;
  elsif p_pattern = 'corners' then
    return array[
      topv[1],
      topv[cardinality(topv)],
      botv[1],
      botv[cardinality(botv)]
    ];
  else
    return array[]::integer[];
  end if;
end;
$$;

CREATE OR REPLACE FUNCTION public.tambola_pattern_matched_cells(
  p_grid jsonb,
  p_marked integer[],
  p_pattern text
) RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  required integer[];
  cells jsonb := '[]'::jsonb;
  r integer; c integer; cell jsonb; val integer;
  marked_count integer := 0;
begin
  required := public.tambola_pattern_required_numbers(p_grid, p_pattern);

  for r in 0..2 loop
    for c in 0..8 loop
      cell := p_grid->r->c;
      if cell is null or cell = 'null'::jsonb then
        continue;
      end if;
      val := (cell#>>'{}')::integer;
      if val = any(required) and val = any(coalesce(p_marked, array[]::integer[])) then
        if p_pattern in ('early_five', 'early5') then
          -- Early five: include marked ticket cells (cap visual set at 5)
          if marked_count < 5 then
            cells := cells || jsonb_build_array(
              jsonb_build_object('row', r, 'col', c, 'value', val)
            );
            marked_count := marked_count + 1;
          end if;
        else
          cells := cells || jsonb_build_array(
            jsonb_build_object('row', r, 'col', c, 'value', val)
          );
        end if;
      end if;
    end loop;
  end loop;

  return cells;
end;
$$;

CREATE OR REPLACE FUNCTION public.tambola_pattern_missing_numbers(
  p_grid jsonb,
  p_marked integer[],
  p_pattern text
) RETURNS integer[]
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  required integer[];
  marked integer[] := coalesce(p_marked, array[]::integer[]);
  on_ticket_marked integer;
  missing integer[] := array[]::integer[];
  x integer;
begin
  required := public.tambola_pattern_required_numbers(p_grid, p_pattern);

  if p_pattern in ('early_five', 'early5') then
    select count(*)::integer into on_ticket_marked
    from unnest(required) n where n = any(marked);
    if on_ticket_marked >= 5 then
      return array[]::integer[];
    end if;
    foreach x in array required loop
      if not (x = any(marked)) then
        missing := array_append(missing, x);
      end if;
    end loop;
    -- Friendly hint: only as many as still needed for early five
    return missing[1:greatest(1, 5 - on_ticket_marked)];
  end if;

  foreach x in array required loop
    if not (x = any(marked)) then
      missing := array_append(missing, x);
    end if;
  end loop;
  return missing;
end;
$$;

CREATE OR REPLACE FUNCTION public.tambola_realtime_topic(p_session_id uuid)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  select 'tambola:session:' || p_session_id::text;
$$;

-- Safe wrapper: try native realtime.send; always HTTP Broadcast when vault secret present.
-- HTTP path is required on this project until realtime.messages partitions exist.
CREATE OR REPLACE FUNCTION public.tambola_broadcast(
  p_session_id uuid,
  p_event text,
  p_payload jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp', 'realtime', 'net', 'vault'
AS $$
declare
  topic text := public.tambola_realtime_topic(p_session_id);
  final_payload jsonb := coalesce(p_payload, '{}'::jsonb) || jsonb_build_object(
    'session_id', p_session_id,
    'event', p_event,
    'emitted_at', now()
  );
  svc text;
  req_id bigint;
  project_url text := 'https://hygfknxbytfyagjfdiwo.supabase.co/realtime/v1/api/broadcast';
begin
  -- Best-effort native DB broadcast (no-ops with WARNING if messages partitions missing)
  begin
    perform realtime.send(final_payload, p_event, topic, false);
  exception when others then
    null;
  end;

  -- Explicit Realtime Broadcast HTTP API (primary reliable path)
  begin
    select ds.decrypted_secret into svc
    from vault.decrypted_secrets ds
    where ds.name = 'supabase_service_role_key'
    limit 1;

    if svc is null or length(svc) < 20 then
      raise warning 'tambola_broadcast: vault secret supabase_service_role_key not configured';
      return;
    end if;

    select net.http_post(
      url := project_url,
      body := jsonb_build_object(
        'messages', jsonb_build_array(
          jsonb_build_object(
            'topic', topic,
            'event', p_event,
            'payload', final_payload,
            'private', false
          )
        )
      ),
      params := '{}'::jsonb,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'apikey', svc,
        'Authorization', 'Bearer ' || svc
      ),
      timeout_milliseconds := 5000
    ) into req_id;
  exception when others then
    raise warning 'tambola_broadcast HTTP failed for % / %: %', p_session_id, p_event, sqlerrm;
  end;
end;
$$;

REVOKE ALL ON FUNCTION public.tambola_broadcast(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tambola_broadcast(uuid, text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.tambola_broadcast(uuid, text, jsonb) TO service_role;

GRANT EXECUTE ON FUNCTION public.tambola_pattern_matched_cells(jsonb, integer[], text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.tambola_pattern_missing_numbers(jsonb, integer[], text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.tambola_pattern_required_numbers(jsonb, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.tambola_realtime_topic(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- host_call_tambola_number — append enriched log + broadcast after success
-- Core auth / lock / number selection / update lines unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_call_tambola_number(
  p_session_id uuid,
  p_number integer DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare s public.game_sessions; available integer[]; chosen integer;
  call_sequence_index integer;
  numbers_remaining integer;
  call_payload jsonb;
begin
 select * into s from public.game_sessions where id=p_session_id for update;
 if s.id is null or s.game_type<>'tambola' or not public.is_group_host(s.group_id,auth.uid()) then raise exception 'Host access required'; end if;
 if s.status<>'active' then raise exception 'Session is not active'; end if;
 if cardinality(s.called_numbers)>=90 then raise exception 'All numbers have been called'; end if;
 if p_number is not null then
   if s.play_mode<>'manual' then raise exception 'Manual number selection disabled in automatic mode'; end if;
   if p_number<1 or p_number>90 or p_number=any(s.called_numbers) then raise exception 'Invalid or already called number'; end if;
   chosen:=p_number;
 else
   select array_agg(x) into available from generate_series(1,90) x where not (x=any(s.called_numbers));
   chosen:=available[1+floor(random()*cardinality(available))::integer];
 end if;
 update public.game_sessions set current_number=chosen,called_numbers=array_append(called_numbers,chosen),next_auto_draw_at=case when play_mode='automatic' then now()+make_interval(secs=>draw_interval_seconds) else null end,updated_at=now() where id=p_session_id;
 -- Celebration payload (sequence after this call)
 call_sequence_index := cardinality(s.called_numbers) + 1;
 numbers_remaining := 90 - call_sequence_index;
 call_payload := jsonb_build_object(
   'number', chosen,
   'call_sequence_index', call_sequence_index,
   'numbers_remaining', numbers_remaining,
   'session_id', p_session_id
 );
 insert into public.game_events(session_id,event_type,actor_id,payload)
 values(p_session_id,'number_called',auth.uid(),call_payload);
 perform public.tambola_broadcast(p_session_id, 'number_called', call_payload);
 return chosen;
end $$;

REVOKE ALL ON FUNCTION public.host_call_tambola_number(uuid, integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.host_call_tambola_number(uuid, integer) TO authenticated;
GRANT ALL ON FUNCTION public.host_call_tambola_number(uuid, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- host_check_tambola_claim — append enriched verified/rejected broadcast
-- Core auth / lock / pattern match / slot update lines unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.host_check_tambola_claim(
  p_claim_id uuid,
  p_force_reject boolean DEFAULT false
) RETURNS public.game_claims
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare c public.game_claims; t public.tambola_tickets; p public.game_prizes; s public.game_sessions; valid boolean; slot integer;
  u public.users;
  player_name text;
  avatar_url text;
  claim_payload jsonb;
  slots_remaining integer;
  matched_cells jsonb;
  missing_numbers integer[];
begin
 select * into c from public.game_claims where id=p_claim_id for update;
 if c.id is null or c.status<>'pending' then raise exception 'Pending claim not found'; end if;
 select * into s from public.game_sessions where id=c.session_id;
 if not public.is_group_host(s.group_id,auth.uid()) then raise exception 'Host access required'; end if;
 select * into t from public.tambola_tickets where id=c.ticket_id;
 select * into p from public.game_prizes where id=c.prize_id for update;
 valid:=not p_force_reject and not p.is_closed and p.awarded_slots<p.total_slots and public.tambola_pattern_matches(t.grid,t.marked_numbers,p.prize_type);
 select * into u from public.users where id = c.user_id;
 player_name := coalesce(u.name, 'Player');
 avatar_url := u.avatar_url;
 if valid then
   slot:=p.awarded_slots+1;
   update public.game_claims set status='verified',verification_details=verification_details||jsonb_build_object('slot',slot,'server_verified',true),verified_at=now(),verified_by=auth.uid() where id=c.id returning * into c;
   update public.game_prizes set awarded_slots=awarded_slots+1,is_closed=(awarded_slots+1>=total_slots) where id=p.id;
   slots_remaining := greatest(0, p.total_slots - slot);
   matched_cells := public.tambola_pattern_matched_cells(t.grid, t.marked_numbers, p.prize_type);
   claim_payload := jsonb_build_object(
     'claim_id', c.id,
     'prize_id', p.id,
     'winner_id', c.user_id,
     'slot', slot,
     'player_name', player_name,
     'avatar_url', avatar_url,
     'claim_type', p.prize_type,
     'ticket_id', t.id,
     'matched_cells', matched_cells,
     'prize_slots_remaining', slots_remaining,
     'is_last_slot_for_this_prize', (slots_remaining = 0),
     'session_id', c.session_id
   );
   insert into public.game_events(session_id,event_type,actor_id,payload)
   values(c.session_id,'claim_verified',auth.uid(),claim_payload);
   perform public.tambola_broadcast(c.session_id, 'claim_verified', claim_payload);
 else
   update public.game_claims set status='rejected',verification_details=verification_details||jsonb_build_object('server_verified',true,'reason',case when p_force_reject then 'host_rejected' else 'pattern_incomplete_or_prize_closed' end),verified_at=now(),verified_by=auth.uid() where id=c.id returning * into c;
   missing_numbers := public.tambola_pattern_missing_numbers(t.grid, t.marked_numbers, p.prize_type);
   claim_payload := jsonb_build_object(
     'claim_id', c.id,
     'prize_id', p.id,
     'user_id', c.user_id,
     'player_name', player_name,
     'claim_type', p.prize_type,
     'ticket_id', t.id,
     'missing_numbers', to_jsonb(missing_numbers),
     'session_id', c.session_id,
     'friendly_hint', 'so_close'
   );
   insert into public.game_events(session_id,event_type,actor_id,payload)
   values(c.session_id,'claim_rejected',auth.uid(),claim_payload);
   perform public.tambola_broadcast(c.session_id, 'claim_rejected', claim_payload);
 end if;
 return c;
end $$;

REVOKE ALL ON FUNCTION public.host_check_tambola_claim(uuid, boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.host_check_tambola_claim(uuid, boolean) TO authenticated;
GRANT ALL ON FUNCTION public.host_check_tambola_claim(uuid, boolean) TO service_role;
