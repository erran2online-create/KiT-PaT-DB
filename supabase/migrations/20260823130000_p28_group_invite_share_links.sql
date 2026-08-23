-- P28: multi-use group share links on top of the existing single-use invites.
--
-- Before this migration group_invites was strictly single-use: one code, one
-- redemption, then status='used' forever. That makes a WhatsApp-style share
-- link unusable (everyone would need their own code) and, worse, makes a
-- second tap of the SAME link by the SAME person who already joined fail
-- with "Already a member of this group" — a hard error for completely normal
-- behaviour (re-opening an old chat message).
--
-- This migration:
--   1. Adds group_invites.max_uses / use_count (both NOT NULL, additive).
--      Existing rows are backfilled max_uses=1, use_count=(status='used').
--      That backfill alone makes every existing single-use row behave
--      identically under the new use_count-based gate below.
--   2. create_group_share_link(p_group_id, p_max_uses default 25,
--      p_valid_days default 14) — host-only — issues a multi-use code.
--   3. Rewrites redeem_group_invite(): the gate is now use_count >= max_uses
--      (not status = 'used'), so both legacy single-use rows (max_uses=1)
--      and new share links (max_uses=25 or whatever the host picked) are
--      handled by one code path. Distinct stable errors:
--        KITPAT_INVITE_INVALID    - code does not exist / blank
--        KITPAT_INVITE_REVOKED    - host revoked it
--        KITPAT_INVITE_EXPIRED    - past expires_at
--        KITPAT_INVITE_EXHAUSTED  - use_count >= max_uses
--      Crucially, a caller who is ALREADY a member of the invite's group is
--      checked FIRST, before any of the above, and always succeeds with
--      { ok:true, already_member:true, group_id } without touching
--      use_count — re-tapping a link you already used is not a fault.
--      The row is locked with SELECT ... FOR UPDATE before the increment so
--      concurrent redemptions can't push use_count past max_uses.
--   4. preview_group_invite(p_invite_code) — anon, no auth required — for a
--      link-preview screen before the user signs in. Returns exactly
--      { group_name, member_count, host_name, valid }: no phone numbers, no
--      member list, no ledger data, nothing else.
--   5. revoke_group_invite(p_invite_code) — host-only — marks a link dead
--      immediately regardless of remaining uses.
--
-- create_group_invite() (the original single-use RPC) is untouched and still
-- works: it inserts a row and relies on the max_uses=1/use_count=0 column
-- defaults, so it produces a row redeem_group_invite treats exactly like a
-- legacy single-use invite. Nothing is dropped.
--
-- Additive only: two new NOT NULL columns with defaults (existing rows
-- backfilled, not left null), two new functions, one CREATE OR REPLACE of an
-- existing RPC (same signature, so no drop needed). No existing row's
-- group_id/invite_code/status/used_by/used_at changes value.

-- ---------------------------------------------------------------------------
-- 1. group_invites.max_uses / use_count
-- ---------------------------------------------------------------------------
ALTER TABLE public.group_invites
  ADD COLUMN IF NOT EXISTS max_uses integer NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS use_count integer NOT NULL DEFAULT 0;

-- Backfill: every existing row is single-use (max_uses=1, already the
-- column default); use_count is 1 for rows already consumed, 0 otherwise
-- (also already the default, so only the 'used' rows need the update).
UPDATE public.group_invites SET use_count = 1 WHERE status = 'used';

ALTER TABLE public.group_invites DROP CONSTRAINT IF EXISTS group_invites_max_uses_positive;
ALTER TABLE public.group_invites
  ADD CONSTRAINT group_invites_max_uses_positive CHECK (max_uses > 0);

ALTER TABLE public.group_invites DROP CONSTRAINT IF EXISTS group_invites_use_count_nonneg;
ALTER TABLE public.group_invites
  ADD CONSTRAINT group_invites_use_count_nonneg CHECK (use_count >= 0);

ALTER TABLE public.group_invites DROP CONSTRAINT IF EXISTS group_invites_use_count_le_max;
ALTER TABLE public.group_invites
  ADD CONSTRAINT group_invites_use_count_le_max CHECK (use_count <= max_uses);

COMMENT ON COLUMN public.group_invites.max_uses IS
  'How many successful redemptions this code allows. 1 = legacy single-use invite (create_group_invite). >1 = multi-use share link (create_group_share_link).';
COMMENT ON COLUMN public.group_invites.use_count IS
  'Successful redemptions so far. redeem_group_invite() rejects with KITPAT_INVITE_EXHAUSTED once use_count >= max_uses. A caller re-redeeming as an existing member does not increment this.';

COMMENT ON TABLE public.group_invites IS
  'Group invite codes: single-use (max_uses=1, via create_group_invite) or multi-use share links (max_uses>1, via create_group_share_link). Join with redeem_group_invite(); preview with preview_group_invite() (anon-callable). Prefer over groups.invite_code.';

-- ---------------------------------------------------------------------------
-- 2. create_group_share_link — host-only, multi-use
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_group_share_link(
  p_group_id uuid,
  p_max_uses integer DEFAULT 25,
  p_valid_days integer DEFAULT 14
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  code text;
  inv public.group_invites;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;
  IF NOT public.is_group_host(p_group_id, uid) THEN
    RAISE EXCEPTION 'KITPAT_NOT_HOST' USING ERRCODE = 'PT403';
  END IF;
  IF p_max_uses IS NULL OR p_max_uses <= 0 THEN
    RAISE EXCEPTION 'KITPAT_INVALID_AMOUNT' USING ERRCODE = 'PT400';
  END IF;
  IF p_valid_days IS NULL OR p_valid_days <= 0 THEN
    RAISE EXCEPTION 'KITPAT_INVALID_AMOUNT' USING ERRCODE = 'PT400';
  END IF;

  -- Unique short code (retry on rare collision), same scheme as create_group_invite.
  FOR i IN 1..8 LOOP
    code := substr(md5(random()::text || clock_timestamp()::text || i::text), 1, 10);
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.group_invites gi WHERE gi.invite_code = code);
  END LOOP;

  INSERT INTO public.group_invites (
    group_id, invite_code, created_by, expires_at, status, max_uses, use_count
  ) VALUES (
    p_group_id, code, uid, now() + make_interval(days => p_valid_days), 'pending', p_max_uses, 0
  ) RETURNING * INTO inv;

  RETURN jsonb_build_object(
    'invite_code', inv.invite_code,
    'url_path', '/join/' || inv.invite_code,
    'expires_at', inv.expires_at,
    'max_uses', inv.max_uses
  );
END;
$$;

COMMENT ON FUNCTION public.create_group_share_link(uuid, integer, integer) IS
  'Host-only. Issues a multi-use share link (default 25 uses, 14-day expiry). Returns exactly { invite_code, url_path, expires_at, max_uses }. Errors: KITPAT_UNAUTHENTICATED / KITPAT_NOT_HOST / KITPAT_INVALID_AMOUNT.';

-- ---------------------------------------------------------------------------
-- 3. redeem_group_invite — rewritten: use_count/max_uses gate, idempotent
--    for existing members
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.redeem_group_invite(
  p_invite_code text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  inv public.group_invites;
  code text := trim(coalesce(p_invite_code, ''));
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;
  IF code = '' THEN
    RAISE EXCEPTION 'KITPAT_INVITE_INVALID' USING ERRCODE = 'PT404';
  END IF;

  SELECT * INTO inv
  FROM public.group_invites
  WHERE invite_code = code
  FOR UPDATE;

  IF inv.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_INVITE_INVALID' USING ERRCODE = 'PT404';
  END IF;

  -- Already a member: succeed idempotently no matter what state the invite
  -- itself is in (revoked/expired/exhausted). Re-tapping an old WhatsApp
  -- link after you already joined is normal, not a fault, and must not
  -- touch use_count.
  IF public.is_group_member(inv.group_id, uid)
     OR public.is_group_host(inv.group_id, uid) THEN
    RETURN jsonb_build_object(
      'ok', true,
      'already_member', true,
      'group_id', inv.group_id
    );
  END IF;

  IF inv.status = 'revoked' THEN
    RAISE EXCEPTION 'KITPAT_INVITE_REVOKED' USING ERRCODE = 'PT403';
  END IF;

  IF inv.status = 'expired'
     OR (inv.expires_at IS NOT NULL AND inv.expires_at <= now()) THEN
    IF inv.status = 'pending' THEN
      UPDATE public.group_invites SET status = 'expired' WHERE id = inv.id;
    END IF;
    RAISE EXCEPTION 'KITPAT_INVITE_EXPIRED' USING ERRCODE = 'PT410';
  END IF;

  IF inv.use_count >= inv.max_uses THEN
    RAISE EXCEPTION 'KITPAT_INVITE_EXHAUSTED' USING ERRCODE = 'PT409';
  END IF;

  INSERT INTO public.members (group_id, user_id, role)
  VALUES (inv.group_id, uid, 'member')
  ON CONFLICT (group_id, user_id) DO NOTHING;

  -- Flip to 'used' once fully consumed so status keeps meaning "no more
  -- redemptions available" for both legacy single-use and share-link rows;
  -- the actual gate above is use_count/max_uses, not this flag.
  UPDATE public.group_invites
  SET use_count = use_count + 1,
      used_by = uid,
      used_at = now(),
      status = CASE WHEN use_count + 1 >= max_uses THEN 'used' ELSE status END
  WHERE id = inv.id
  RETURNING * INTO inv;

  RETURN jsonb_build_object(
    'ok', true,
    'already_member', false,
    'group_id', inv.group_id,
    'invite_code', inv.invite_code,
    'use_count', inv.use_count,
    'max_uses', inv.max_uses
  );
END;
$$;

COMMENT ON FUNCTION public.redeem_group_invite(text) IS
  'Authenticated. Joins caller to the invite''s group. Already-a-member is a success: { ok:true, already_member:true, group_id }, use_count untouched. Otherwise increments use_count under a row lock and joins. Errors: KITPAT_UNAUTHENTICATED / KITPAT_INVITE_INVALID / KITPAT_INVITE_REVOKED / KITPAT_INVITE_EXPIRED / KITPAT_INVITE_EXHAUSTED.';

-- ---------------------------------------------------------------------------
-- 4. preview_group_invite — anon, no auth, minimal fields only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.preview_group_invite(
  p_invite_code text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  inv public.group_invites;
  grp public.groups;
  code text := trim(coalesce(p_invite_code, ''));
  v_host_name text;
  v_member_count integer;
  v_valid boolean;
BEGIN
  IF code = '' THEN
    RAISE EXCEPTION 'KITPAT_INVITE_INVALID' USING ERRCODE = 'PT404';
  END IF;

  SELECT * INTO inv FROM public.group_invites WHERE invite_code = code;
  IF inv.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_INVITE_INVALID' USING ERRCODE = 'PT404';
  END IF;

  SELECT * INTO grp FROM public.groups WHERE id = inv.group_id;
  IF grp.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_INVITE_INVALID' USING ERRCODE = 'PT404';
  END IF;

  SELECT coalesce(u.name, 'Host') INTO v_host_name
  FROM public.users u WHERE u.id = grp.host_id;

  SELECT count(*)::integer INTO v_member_count
  FROM public.members m WHERE m.group_id = grp.id;

  v_valid := inv.status <> 'revoked'
    AND NOT (inv.status = 'expired' OR (inv.expires_at IS NOT NULL AND inv.expires_at <= now()))
    AND inv.use_count < inv.max_uses;

  -- Deliberately nothing else: no phone numbers, no member list, no ledger.
  RETURN jsonb_build_object(
    'group_name', grp.name,
    'member_count', coalesce(v_member_count, 0),
    'host_name', coalesce(v_host_name, 'Host'),
    'valid', v_valid
  );
END;
$$;

COMMENT ON FUNCTION public.preview_group_invite(text) IS
  'Anon-callable, no auth required. Returns exactly { group_name, member_count, host_name, valid } for a link-preview screen before sign-in. Never returns phone numbers, member lists, or ledger data. Errors: KITPAT_INVITE_INVALID.';

-- ---------------------------------------------------------------------------
-- 5. revoke_group_invite — host-only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.revoke_group_invite(
  p_invite_code text
) RETURNS public.group_invites
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  inv public.group_invites;
  code text := trim(coalesce(p_invite_code, ''));
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'KITPAT_UNAUTHENTICATED' USING ERRCODE = 'PT401';
  END IF;
  IF code = '' THEN
    RAISE EXCEPTION 'KITPAT_INVITE_INVALID' USING ERRCODE = 'PT404';
  END IF;

  SELECT * INTO inv FROM public.group_invites WHERE invite_code = code FOR UPDATE;
  IF inv.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_INVITE_INVALID' USING ERRCODE = 'PT404';
  END IF;
  IF NOT public.is_group_host(inv.group_id, uid) THEN
    RAISE EXCEPTION 'KITPAT_NOT_HOST' USING ERRCODE = 'PT403';
  END IF;

  UPDATE public.group_invites
  SET status = 'revoked'
  WHERE id = inv.id
  RETURNING * INTO inv;

  RETURN inv;
END;
$$;

COMMENT ON FUNCTION public.revoke_group_invite(text) IS
  'Host-only. Marks the invite revoked; redeem_group_invite then raises KITPAT_INVITE_REVOKED for anyone not already a member. Errors: KITPAT_UNAUTHENTICATED / KITPAT_INVITE_INVALID / KITPAT_NOT_HOST.';

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.create_group_share_link(uuid, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.preview_group_invite(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revoke_group_invite(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.redeem_group_invite(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_group_share_link(uuid, integer, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revoke_group_invite(text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.redeem_group_invite(text) TO authenticated, service_role;

-- The one deliberately anon-callable RPC in this migration.
GRANT EXECUTE ON FUNCTION public.preview_group_invite(text) TO anon, authenticated, service_role;
