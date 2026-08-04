-- P6.4: Per-recipient, single-use group invites (replaces static groups.invite_code for new flows).
-- groups.invite_code is retained for backward compatibility; new invites use group_invites only.

-- ---------------------------------------------------------------------------
-- 1. group_invites
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.group_invites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id uuid NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
  invite_code text NOT NULL,
  created_by uuid NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  used_by uuid REFERENCES public.users(id),
  used_at timestamptz,
  expires_at timestamptz,
  status text NOT NULL DEFAULT 'pending',
  CONSTRAINT group_invites_invite_code_key UNIQUE (invite_code),
  CONSTRAINT group_invites_status_check CHECK (
    status = ANY (ARRAY['pending'::text, 'used'::text, 'expired'::text, 'revoked'::text])
  ),
  CONSTRAINT group_invites_used_consistency CHECK (
    (status = 'used' AND used_by IS NOT NULL AND used_at IS NOT NULL)
    OR (status <> 'used')
  )
);

CREATE INDEX IF NOT EXISTS idx_group_invites_group ON public.group_invites (group_id);
CREATE INDEX IF NOT EXISTS idx_group_invites_status ON public.group_invites (status) WHERE status = 'pending';

COMMENT ON TABLE public.group_invites IS
  'Single-use per-recipient group invite codes. Prefer over groups.invite_code for new joins.';

ALTER TABLE public.group_invites ENABLE ROW LEVEL SECURITY;

-- Hosts can read invites for their groups; no direct client writes (RPCs only)
DROP POLICY IF EXISTS group_invites_read_host ON public.group_invites;
CREATE POLICY group_invites_read_host ON public.group_invites
  FOR SELECT TO authenticated
  USING (public.is_group_host(group_id, (SELECT auth.uid())));

REVOKE ALL ON TABLE public.group_invites FROM anon;
GRANT SELECT ON TABLE public.group_invites TO authenticated;
GRANT ALL ON TABLE public.group_invites TO service_role;

-- ---------------------------------------------------------------------------
-- 2. create_group_invite — host-only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_group_invite(
  p_group_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  uid uuid := auth.uid();
  code text;
  inv public.group_invites;
  link_base text := 'https://kitpat.app/join/';
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if not public.is_group_host(p_group_id, uid) then
    raise exception 'Host access required';
  end if;

  -- Unique short code (retry on rare collision with groups.invite_code / group_invites)
  for i in 1..8 loop
    code := substr(md5(random()::text || clock_timestamp()::text || i::text), 1, 10);
    exit when not exists (select 1 from public.group_invites gi where gi.invite_code = code);
  end loop;

  insert into public.group_invites (
    group_id, invite_code, created_by, expires_at, status
  ) values (
    p_group_id, code, uid, now() + interval '7 days', 'pending'
  ) returning * into inv;

  return jsonb_build_object(
    'id', inv.id,
    'group_id', inv.group_id,
    'invite_code', inv.invite_code,
    'invite_link', link_base || inv.invite_code,
    'expires_at', inv.expires_at,
    'status', inv.status,
    'created_at', inv.created_at
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. redeem_group_invite — any authenticated user, single-use
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.redeem_group_invite(
  p_invite_code text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  uid uuid := auth.uid();
  inv public.group_invites;
  code text := trim(coalesce(p_invite_code, ''));
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if code = '' then
    raise exception 'Invalid invite code';
  end if;

  select * into inv
  from public.group_invites
  where invite_code = code
  for update;

  if inv.id is null then
    raise exception 'Invalid invite code';
  end if;

  if inv.status = 'revoked' then
    raise exception 'Invite has been revoked';
  end if;

  if inv.status = 'used' then
    raise exception 'Invite has already been used';
  end if;

  -- Treat past expires_at as expired even if status still pending
  if inv.status = 'expired'
     or (inv.expires_at is not null and inv.expires_at <= now()) then
    if inv.status = 'pending' then
      update public.group_invites set status = 'expired' where id = inv.id;
    end if;
    raise exception 'Invite has expired';
  end if;

  if inv.status <> 'pending' then
    raise exception 'Invalid invite code';
  end if;

  if public.is_group_member(inv.group_id, uid)
     or public.is_group_host(inv.group_id, uid) then
    raise exception 'Already a member of this group';
  end if;

  insert into public.members (group_id, user_id, role)
  values (inv.group_id, uid, 'member')
  on conflict (group_id, user_id) do nothing;

  update public.group_invites
  set status = 'used',
      used_by = uid,
      used_at = now()
  where id = inv.id
    and status = 'pending'
  returning * into inv;

  if inv.status is distinct from 'used' then
    raise exception 'Invite has already been used';
  end if;

  return jsonb_build_object(
    'group_id', inv.group_id,
    'invite_code', inv.invite_code,
    'status', inv.status,
    'used_at', inv.used_at,
    'member_user_id', uid
  );
end;
$$;

REVOKE ALL ON FUNCTION public.create_group_invite(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.redeem_group_invite(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_group_invite(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.redeem_group_invite(text) TO authenticated, service_role;

COMMENT ON FUNCTION public.create_group_invite(uuid) IS
  'Host-only: create a single-use pending group invite (7-day expiry) and return code + share link.';
COMMENT ON FUNCTION public.redeem_group_invite(text) IS
  'Authenticated: redeem a pending single-use invite; joins caller as member. Distinct errors for used/expired/invalid.';
