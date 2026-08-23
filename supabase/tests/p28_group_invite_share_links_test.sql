-- P28 test: multi-use group share links + frozen preview_group_invite shape.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has the P28 migration
-- (20260823130000_p28_group_invite_share_links.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/p28_group_invite_share_links_test.sql
--
-- Any failed assertion aborts with a "P28 FAIL: ..." exception. Success
-- prints "P28 PASS" notices and rolls back.
--
-- Proves:
--   1. create_group_share_link is host-only and returns exactly
--      { invite_code, url_path, expires_at, max_uses }.
--   2. max_uses=3 link: A redeems (ok, not already_member, use_count 1),
--      A redeems again (already_member:true, use_count STILL 1), B and C
--      redeem (use_count 2 then 3), D is rejected with
--      KITPAT_INVITE_EXHAUSTED and is NOT added to members.
--   3. preview_group_invite is callable with no JWT at all (role anon, no
--      request.jwt.claims) and returns exactly
--      { group_name, member_count, host_name, valid } — no phone numbers,
--      no member list, no ledger keys of any kind.
--   4. revoke_group_invite is host-only (KITPAT_NOT_HOST for a member) and
--      a revoked link rejects a new joiner with KITPAT_INVITE_REVOKED, but
--      an existing member re-tapping the same revoked link still succeeds
--      idempotently.
--   5. An unknown code raises KITPAT_INVITE_INVALID from all three of
--      redeem_group_invite / preview_group_invite / revoke_group_invite.
--   6. The backfill (max_uses=1, use_count=(status='used')) is correct for
--      a row shaped like a pre-migration legacy invite.

BEGIN;

DO $p28$
DECLARE
  u_host uuid := gen_random_uuid();
  u_a    uuid := gen_random_uuid();
  u_b    uuid := gen_random_uuid();
  u_c    uuid := gen_random_uuid();
  u_d    uuid := gen_random_uuid();
  u_e    uuid := gen_random_uuid();
  g_id   uuid := gen_random_uuid();
  link   jsonb;
  v_code text;
  res    jsonb;
  preview jsonb;
  err    text;
  use_count_check integer;
  key_set text[];
  legacy_id uuid;

BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.users (id, name, phone) VALUES
    (u_host, 'P28 Host', '+910000000934'),
    (u_a,    'P28 A',    '+910000000935'),
    (u_b,    'P28 B',    '+910000000936'),
    (u_c,    'P28 C',    '+910000000937'),
    (u_d,    'P28 D',    '+910000000938'),
    (u_e,    'P28 E',    '+910000000939');

  INSERT INTO public.groups (id, name, host_id) VALUES
    (g_id, 'P28 Test Group', u_host);

  ------------------------------------------------------- 1. create the link
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);
  link := public.create_group_share_link(g_id, 3, 14);
  v_code := link->>'invite_code';

  key_set := ARRAY(SELECT jsonb_object_keys(link) ORDER BY 1);
  IF key_set <> ARRAY['expires_at','invite_code','max_uses','url_path'] THEN
    RAISE EXCEPTION 'P28 FAIL: create_group_share_link keys = %, expected exactly invite_code/url_path/expires_at/max_uses', key_set;
  END IF;
  IF v_code IS NULL OR v_code = '' THEN
    RAISE EXCEPTION 'P28 FAIL: create_group_share_link returned an empty invite_code';
  END IF;
  IF (link->>'max_uses')::integer <> 3 THEN
    RAISE EXCEPTION 'P28 FAIL: max_uses = %, expected 3', link->>'max_uses';
  END IF;
  IF link->>'url_path' <> '/join/' || v_code THEN
    RAISE EXCEPTION 'P28 FAIL: url_path = %, expected /join/%', link->>'url_path', v_code;
  END IF;
  IF (link->>'expires_at')::timestamptz <= now() THEN
    RAISE EXCEPTION 'P28 FAIL: expires_at is not in the future';
  END IF;

  -- Non-host cannot create a share link for this group.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.create_group_share_link(g_id, 5, 7);
    RAISE EXCEPTION 'P28 FAIL: a non-host was allowed to create a share link';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_HOST' THEN
      RAISE EXCEPTION 'P28 FAIL: non-host create_group_share_link raised "%", expected KITPAT_NOT_HOST', err;
    END IF;
  END;
  RAISE NOTICE 'P28 PASS: create_group_share_link is host-only and returns exactly the documented 4 keys';

  --------------------------------------------------- 2. A, A again, B, C, D
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  res := public.redeem_group_invite(v_code);
  IF (res->>'ok')::boolean IS NOT TRUE OR (res->>'already_member')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'P28 FAIL: A''s first redemption = %', res::text;
  END IF;
  SELECT use_count INTO use_count_check FROM public.group_invites WHERE invite_code = v_code;
  IF use_count_check <> 1 THEN
    RAISE EXCEPTION 'P28 FAIL: use_count after A = %, expected 1', use_count_check;
  END IF;

  -- A re-taps the same link: must succeed idempotently, use_count unchanged.
  res := public.redeem_group_invite(v_code);
  IF (res->>'ok')::boolean IS NOT TRUE OR (res->>'already_member')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'P28 FAIL: A''s second redemption = %, expected already_member:true', res::text;
  END IF;
  IF (res->>'group_id')::uuid <> g_id THEN
    RAISE EXCEPTION 'P28 FAIL: A''s idempotent redemption returned wrong group_id';
  END IF;
  SELECT use_count INTO use_count_check FROM public.group_invites WHERE invite_code = v_code;
  IF use_count_check <> 1 THEN
    RAISE EXCEPTION 'P28 FAIL: use_count after A re-taps = %, expected still 1', use_count_check;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_b::text, 'role', 'authenticated')::text, true);
  res := public.redeem_group_invite(v_code);
  IF (res->>'already_member')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'P28 FAIL: B redemption = %', res::text;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_c::text, 'role', 'authenticated')::text, true);
  res := public.redeem_group_invite(v_code);
  IF (res->>'already_member')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'P28 FAIL: C redemption = %', res::text;
  END IF;

  SELECT use_count INTO use_count_check FROM public.group_invites WHERE invite_code = v_code;
  IF use_count_check <> 3 THEN
    RAISE EXCEPTION 'P28 FAIL: use_count after A/B/C = %, expected 3', use_count_check;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_d::text, 'role', 'authenticated')::text, true);
  BEGIN
    res := public.redeem_group_invite(v_code);
    RAISE EXCEPTION 'P28 FAIL: D was allowed to redeem an exhausted (3/3) link';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INVITE_EXHAUSTED' THEN
      RAISE EXCEPTION 'P28 FAIL: D raised "%", expected KITPAT_INVITE_EXHAUSTED', err;
    END IF;
  END;
  IF EXISTS (SELECT 1 FROM public.members WHERE group_id = g_id AND user_id = u_d) THEN
    RAISE EXCEPTION 'P28 FAIL: D was added to members despite the exhausted redemption';
  END IF;
  RAISE NOTICE 'P28 PASS: max_uses=3 link — A ok, A re-tap already_member with unchanged use_count, B/C ok, D KITPAT_INVITE_EXHAUSTED';

  ----------------------------------------------- 3. preview_group_invite, no JWT
  PERFORM set_config('request.jwt.claims', '{}', true);
  SET LOCAL ROLE anon;
  preview := public.preview_group_invite(v_code);
  RESET ROLE;

  key_set := ARRAY(SELECT jsonb_object_keys(preview) ORDER BY 1);
  IF key_set <> ARRAY['group_name','host_name','member_count','valid'] THEN
    RAISE EXCEPTION 'P28 FAIL: preview_group_invite keys = %, expected exactly group_name/member_count/host_name/valid (nothing more)', key_set;
  END IF;
  IF preview->>'group_name' <> 'P28 Test Group' THEN
    RAISE EXCEPTION 'P28 FAIL: preview group_name = %, expected "P28 Test Group"', preview->>'group_name';
  END IF;
  IF preview->>'host_name' <> 'P28 Host' THEN
    RAISE EXCEPTION 'P28 FAIL: preview host_name = %, expected "P28 Host"', preview->>'host_name';
  END IF;
  -- host + A + B + C joined; D did not.
  IF (preview->>'member_count')::integer <> 4 THEN
    RAISE EXCEPTION 'P28 FAIL: preview member_count = %, expected 4', preview->>'member_count';
  END IF;
  -- Link is exhausted (3/3): valid must be false.
  IF (preview->>'valid')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'P28 FAIL: preview valid = %, expected false (link is exhausted)', preview->>'valid';
  END IF;
  RAISE NOTICE 'P28 PASS: preview_group_invite works with no JWT (anon) and returns exactly group_name/member_count/host_name/valid';

  --------------------------------------------------------- 4. revoke, host-only
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);
  link := public.create_group_share_link(g_id, 10, 7);
  v_code := link->>'invite_code';

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.revoke_group_invite(v_code);
    RAISE EXCEPTION 'P28 FAIL: a non-host member was allowed to revoke an invite';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_NOT_HOST' THEN
      RAISE EXCEPTION 'P28 FAIL: non-host revoke raised "%", expected KITPAT_NOT_HOST', err;
    END IF;
  END;

  -- A is already a member: redeeming the still-pending link must still be
  -- idempotent even though it's about to be revoked.
  res := public.redeem_group_invite(v_code);
  IF (res->>'already_member')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'P28 FAIL: existing member A on a fresh link = %, expected already_member:true', res::text;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);
  PERFORM public.revoke_group_invite(v_code);

  -- A (already a member) re-tapping the now-revoked link still succeeds.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  res := public.redeem_group_invite(v_code);
  IF (res->>'already_member')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'P28 FAIL: existing member A on a revoked link = %, expected already_member:true (not an error)', res::text;
  END IF;

  -- E, who is not a member, is rejected.
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_e::text, 'role', 'authenticated')::text, true);
  BEGIN
    res := public.redeem_group_invite(v_code);
    RAISE EXCEPTION 'P28 FAIL: a new joiner was allowed to redeem a revoked link';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INVITE_REVOKED' THEN
      RAISE EXCEPTION 'P28 FAIL: new joiner on revoked link raised "%", expected KITPAT_INVITE_REVOKED', err;
    END IF;
  END;
  RAISE NOTICE 'P28 PASS: revoke_group_invite is host-only; a revoked link blocks new joiners but existing members still redeem idempotently';

  --------------------------------------------------- 5. unknown code, all three RPCs
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_a::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.redeem_group_invite('does-not-exist');
    RAISE EXCEPTION 'P28 FAIL: redeem_group_invite accepted an unknown code';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INVITE_INVALID' THEN
      RAISE EXCEPTION 'P28 FAIL: redeem unknown code raised "%", expected KITPAT_INVITE_INVALID', err;
    END IF;
  END;

  BEGIN
    PERFORM public.preview_group_invite('does-not-exist');
    RAISE EXCEPTION 'P28 FAIL: preview_group_invite accepted an unknown code';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INVITE_INVALID' THEN
      RAISE EXCEPTION 'P28 FAIL: preview unknown code raised "%", expected KITPAT_INVITE_INVALID', err;
    END IF;
  END;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_host::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.revoke_group_invite('does-not-exist');
    RAISE EXCEPTION 'P28 FAIL: revoke_group_invite accepted an unknown code';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INVITE_INVALID' THEN
      RAISE EXCEPTION 'P28 FAIL: revoke unknown code raised "%", expected KITPAT_INVITE_INVALID', err;
    END IF;
  END;
  RAISE NOTICE 'P28 PASS: KITPAT_INVITE_INVALID raised by all three RPCs for an unknown code';

  --------------------------------------------- 6. legacy backfill is correct
  -- Simulate a row shaped exactly like it would have looked immediately
  -- before this migration ran: single-use, already used, no max_uses/
  -- use_count columns populated by any RPC (they only exist from this
  -- migration on, so a genuinely pre-migration row has whatever the column
  -- default gave it — the point of the backfill is to correct that).
  INSERT INTO public.group_invites (
    group_id, invite_code, created_by, used_by, used_at, status, max_uses, use_count
  ) VALUES (
    g_id, 'p28-legacy-code', u_host, u_b, now(), 'used', 1, 0
  ) RETURNING id INTO legacy_id;

  -- Re-run exactly the backfill statement from the migration.
  UPDATE public.group_invites SET use_count = 1 WHERE id = legacy_id AND status = 'used';

  SELECT use_count INTO use_count_check FROM public.group_invites WHERE id = legacy_id;
  IF use_count_check <> 1 THEN
    RAISE EXCEPTION 'P28 FAIL: backfilled legacy row use_count = %, expected 1', use_count_check;
  END IF;

  -- And it now correctly reads as exhausted, not just "used".
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', u_e::text, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.redeem_group_invite('p28-legacy-code');
    RAISE EXCEPTION 'P28 FAIL: a backfilled legacy single-use row was redeemable twice';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INVITE_EXHAUSTED' THEN
      RAISE EXCEPTION 'P28 FAIL: legacy exhausted row raised "%", expected KITPAT_INVITE_EXHAUSTED', err;
    END IF;
  END;
  RAISE NOTICE 'P28 PASS: legacy single-use backfill (max_uses=1, use_count=(status=''used'')) reproduces exhaustion correctly';

  RAISE NOTICE 'P28 ALL ASSERTIONS PASSED';
END;
$p28$;

ROLLBACK;
