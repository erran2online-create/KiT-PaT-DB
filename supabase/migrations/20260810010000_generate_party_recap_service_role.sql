-- P12: Allow n8n (service_role) to generate party recaps without auth.uid().
-- Simpler than minting a host JWT from n8n. Authenticated callers keep
-- existing host/member checks; service_role may regenerate freely.

CREATE OR REPLACE FUNCTION public.generate_party_recap(
  p_event_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  uid uuid := auth.uid();
  is_service boolean := (coalesce(auth.role(), '') = 'service_role');
  ev public.events;
  existing public.memory_artifacts;
  is_host boolean;
  is_member boolean;
  recap jsonb;
  attendance_n integer;
  winners jsonb;
  top_badge jsonb;
  photo_ids jsonb;
  artifact public.memory_artifacts;
  may_regenerate boolean;
begin
  if uid is null and not is_service then
    raise exception 'Authentication required';
  end if;

  select * into ev from public.events where id = p_event_id;
  if ev.id is null then
    raise exception 'Event not found';
  end if;

  if is_service then
    is_host := true;
    is_member := true;
  else
    is_host := public.is_group_host(ev.group_id, uid);
    is_member := public.is_group_member(ev.group_id, uid);
    if not is_member and not is_host then
      raise exception 'Group membership required';
    end if;
  end if;

  select * into existing
  from public.memory_artifacts
  where event_id = p_event_id
    and artifact_type = 'party_recap'
  order by created_at desc
  limit 1;

  -- Cached read for non-hosts; host or service_role may regenerate
  may_regenerate := is_host or is_service;
  if existing.id is not null and not may_regenerate then
    return jsonb_build_object(
      'artifact_id', existing.id,
      'event_id', p_event_id,
      'cached', true,
      'recap', existing.payload,
      'created_at', existing.created_at
    );
  end if;

  select count(*)::integer into attendance_n
  from public.attendance a
  where a.event_id = p_event_id;

  select coalesce(jsonb_agg(w order by w->>'verified_at', w->>'prize_name'), '[]'::jsonb)
  into winners
  from (
    select jsonb_build_object(
      'user_id', c.user_id,
      'user_name', u.name,
      'prize_id', p.id,
      'prize_type', p.prize_type,
      'prize_name', p.display_name,
      'session_id', s.id,
      'game_type', s.game_type,
      'verified_at', c.verified_at
    ) as w
    from public.game_sessions s
    join public.game_claims c on c.session_id = s.id and c.status = 'verified'
    join public.game_prizes p on p.id = c.prize_id
    left join public.users u on u.id = c.user_id
    where s.event_id = p_event_id
  ) q;

  select jsonb_build_object(
    'badge_id', bd.id,
    'name', bd.name,
    'emoji', bd.emoji,
    'category', bd.category,
    'user_id', mb.user_id,
    'user_name', u.name,
    'awarded_at', mb.awarded_at
  )
  into top_badge
  from public.member_badges mb
  join public.badge_definitions bd on bd.id = mb.badge_id
  left join public.users u on u.id = mb.user_id
  where mb.event_id = p_event_id
  order by mb.awarded_at desc nulls last
  limit 1;

  select coalesce(jsonb_agg(m.id order by m.uploaded_at), '[]'::jsonb)
  into photo_ids
  from public.media m
  where m.event_id = p_event_id
    and (
      m.media_type = 'photo'
      or m.asset_type = 'image'
    );

  recap := jsonb_build_object(
    'event_id', ev.id,
    'group_id', ev.group_id,
    'theme', ev.theme,
    'party_date', ev.party_date,
    'generated_at', now(),
    'attendance_count', attendance_n,
    'winners', winners,
    'top_badge', top_badge,
    'photo_ids', photo_ids
  );

  if existing.id is not null and may_regenerate then
    update public.memory_artifacts
    set payload = recap,
        status = 'ready',
        title = coalesce(title, 'Party Recap'),
        updated_at = now(),
        generated_by = 'generate_party_recap'
    where id = existing.id
    returning * into artifact;

    return jsonb_build_object(
      'artifact_id', artifact.id,
      'event_id', p_event_id,
      'cached', false,
      'regenerated', true,
      'recap', artifact.payload,
      'created_at', artifact.created_at
    );
  end if;

  insert into public.memory_artifacts (
    group_id, event_id, artifact_type, title, payload, generated_by, status
  ) values (
    ev.group_id, ev.id, 'party_recap', 'Party Recap', recap, 'generate_party_recap', 'ready'
  ) returning * into artifact;

  return jsonb_build_object(
    'artifact_id', artifact.id,
    'event_id', p_event_id,
    'cached', false,
    'regenerated', false,
    'recap', artifact.payload,
    'created_at', artifact.created_at
  );
end;
$$;

COMMENT ON FUNCTION public.generate_party_recap(uuid) IS
  'Assemble party recap JSON into memory_artifacts. Members read cached; host or service_role regenerates (n8n).';
