-- P32: host_call_tambola_number must reject direct calls in automatic mode.
--
-- Live diagnostic already run before writing this (not re-queried; no DB
-- access): cron job 'tambola-auto-draws' runs every 5s, ACTIVE, 363,615
-- runs, 100% succeeded, zero failures.
--
-- The bug: the frontend runs its own setInterval calling numbers while the
-- server (pg_cron -> process_due_tambola_auto_draws -> host_call_tambola_
-- number) also draws for automatic-mode sessions. Two clocks. When the
-- host's phone screen locks, the browser timer throttles/stalls or fires
-- late, producing a stall or a double-draw race against the server's own
-- draw. Reading host_call_tambola_number (as it stood before this
-- migration, in 20260803110000_tambola_celebration_broadcasts.sql) shows
-- exactly why: it only rejected an EXPLICIT p_number in automatic mode
-- ("Manual number selection disabled in automatic mode"); a call with
-- p_number = NULL (the default) fell through to the random-draw branch
-- unconditionally, with no play_mode check at all — so a client polling
-- this RPC with no explicit number in automatic mode was never rejected,
-- which is precisely the second clock described above.
--
-- Investigation requested alongside the fix: confirm that a manual or
-- non-active session can never be picked up by process_due_tambola_auto_
-- draws() through its next_auto_draw_at gate. Read in full
-- (20260803100000_tambola_variants_and_auto_calling.sql): its outer cursor
-- query filters `game_type='tambola' AND play_mode='automatic' AND
-- status='active' AND next_auto_draw_at IS NOT NULL AND next_auto_draw_at
-- <= now()`, and its inner catch-up loop re-checks the identical
-- `play_mode='automatic' AND status='active'` condition on every iteration.
-- It does not rely on next_auto_draw_at alone. Every writer of
-- next_auto_draw_at across the codebase was also checked:
--   - host_call_tambola_number: `CASE WHEN play_mode='automatic' THEN
--     now()+interval ELSE NULL END` on every call.
--   - host_start_tambola: same CASE-on-play_mode pattern.
--   - host_pause_tambola: unconditionally sets it to NULL.
--   - host_start_auto_calling: sets it to now(), but only ever reaches that
--     line after its own `IF play_mode <> 'automatic' THEN RAISE EXCEPTION`
--     guard earlier in the same function body — unreachable for a manual
--     session.
-- CONCLUSION: no manual or non-active session can ever have a non-null,
-- due next_auto_draw_at, and even if one somehow did, the reader's own
-- explicit play_mode/status filters would still exclude it. This is not a
-- bug.
--
-- The fix, and why process_due_tambola_auto_draws needs one small change
-- too: a blanket "reject any call when play_mode='automatic'" guard cannot
-- live in host_call_tambola_number alone, because process_due_tambola_
-- auto_draws() is host_call_tambola_number's ONLY internal caller (grepped
-- across every migration to confirm) and it reaches this same function by
-- impersonating the session's real host via
-- set_config('request.jwt.claim.sub', r.host_id::text, true) for rows it
-- already filtered to play_mode='automatic'. auth.uid() during that
-- server-driven call is therefore indistinguishable from the same host
-- calling directly over the client API with their own JWT — both present
-- as "this exact host, authenticated". A guard keyed on auth.uid()/host
-- membership alone would either let the frontend's direct call back in, or
-- break the server's own draw. The distinguishing signal has to be WHICH
-- caller this is, not WHO — so process_due_tambola_auto_draws now also
-- impersonates role=service_role (same set_config('request.jwt.claim...',
-- ..., true) mechanism it already uses for sub), and host_call_tambola_
-- number's new guard exempts exactly that role, mirroring the service_role
-- bypass pattern this codebase already uses elsewhere (generate_party_
-- recap, P12) for the identical "trusted server, no real end-user session"
-- situation.
--
-- host_call_tambola_number now rejects ANY direct, non-service_role call —
-- with or without an explicit p_number — when the session's
-- play_mode='automatic', raising the stable code
-- KITPAT_AUTO_MODE_SERVER_DRIVEN (PT409). This makes the old narrower
-- "explicit number in automatic mode" check unreachable for a genuine
-- client call (play_mode has exactly two values, and the new guard already
-- exits for the only case that old check ever fired on), so that dead
-- branch is removed rather than left behind as confusing, unreachable
-- code. Manual mode is completely unaffected — a manual host must still
-- call numbers by hand — and the server's own automatic-mode draw path is
-- unaffected functionally: it now explicitly identifies itself as
-- service_role instead of relying on an accident of omission.
--
-- Additive: two CREATE OR REPLACE calls on existing functions, same
-- signatures. host_call_tambola_number's LANGUAGE, SECURITY DEFINER,
-- search_path, and every existing GRANT/REVOKE are preserved exactly as
-- they already were.

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
 if s.play_mode='automatic' and coalesce(auth.role(),'')<>'service_role' then raise exception 'KITPAT_AUTO_MODE_SERVER_DRIVEN' using errcode='PT409'; end if;
 if cardinality(s.called_numbers)>=90 then raise exception 'All numbers have been called'; end if;
 if p_number is not null then
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

COMMENT ON FUNCTION public.host_call_tambola_number(uuid, integer) IS
  'Host-only. Manual mode: host calls numbers by hand. Automatic mode: server-driven only, exclusively via process_due_tambola_auto_draws() (which identifies itself as service_role) — a direct client call raises KITPAT_AUTO_MODE_SERVER_DRIVEN.';

REVOKE ALL ON FUNCTION public.host_call_tambola_number(uuid, integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.host_call_tambola_number(uuid, integer) TO authenticated;
GRANT ALL ON FUNCTION public.host_call_tambola_number(uuid, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- process_due_tambola_auto_draws — identify itself as service_role so the
-- new guard above recognises this as the trusted server path, not a direct
-- client call impersonating the host. Everything else (the selection query,
-- the catch-up loop, its own play_mode/status filters) is unchanged.
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
    -- Impersonate session host (existing) + service_role (new): the host
    -- claim satisfies host_call_tambola_number's own is_group_host check,
    -- and the service_role claim is what its new automatic-mode guard
    -- exempts from KITPAT_AUTO_MODE_SERVER_DRIVEN.
    perform set_config('request.jwt.claim.sub', r.host_id::text, true);
    perform set_config('request.jwt.claim.role', 'service_role', true);

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
