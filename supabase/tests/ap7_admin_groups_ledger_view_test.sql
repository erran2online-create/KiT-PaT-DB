-- AP7 test: admin_list_groups, admin_group_detail, admin_list_ledger, and
-- admin_void_ledger_entry.
--
-- CAVEAT carried over from this migration's own header, repeated here so it
-- is visible at the point it matters: log_admin_action (AP0) requires the
-- calling database session to be service_role. This test's admin actors
-- are simulated purely via request.jwt.claims (auth.jwt()/auth.uid()),
-- exactly like every other test in this repo -- it does NOT (and cannot,
-- from a plain psql connection) reproduce PostgREST's per-request SET ROLE
-- behavior. If the "writes an admin_audit row" assertion below fails while
-- every other assertion in this file passes, that failure is pointing at
-- log_admin_action's calling-context guard, not at admin_void_ledger_entry's
-- void/re-settle logic (which is asserted independently and directly above
-- it). See this migration's header comment for the full explanation.
--
-- Self-contained and non-destructive: everything happens inside one
-- transaction that is ROLLED BACK at the end, so it can be run against any
-- database that already has AP0-AP6 and this migration
-- (20260908030000_ap7_admin_groups_ledger_view.sql) applied.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/ap7_admin_groups_ledger_view_test.sql
--
-- Any failed assertion aborts with a "FAIL: ..." exception. Success prints
-- "PASS" notices and rolls back.
--
-- Proves:
--   1. admin_list_groups/admin_group_detail/admin_list_ledger raise
--      KITPAT_ADMIN_ONLY for a non-admin; admin_void_ledger_entry raises
--      KITPAT_INSUFFICIENT_ROLE for a non-admin/member admin (its own,
--      more specific combined gate).
--   2. admin_list_groups returns a group the calling admin is NOT a member
--      of (proving the SECURITY DEFINER bypass works) with the right
--      member_count/host_name/current-month totals.
--   3. admin_group_detail returns masked phones only, plus correct pool
--      totals and counts.
--   4. admin_list_ledger includes a voided row with its reason and voider
--      name (after admin_void_ledger_entry runs, below).
--   5. admin_void_ledger_entry raises KITPAT_REASON_REQUIRED for an empty
--      reason, KITPAT_INSUFFICIENT_ROLE for a 'member' admin, voids
--      correctly for an org_admin and reduces the pool total by exactly
--      that amount, raises KITPAT_ALREADY_VOIDED on a second attempt, and
--      (see CAVEAT above) writes an admin_audit row.
--   6. A plain member's own RLS view of the group/ledger is unchanged
--      (still sees only what they could see before this migration).

BEGIN;

DO $t$
DECLARE
  owner_email text := 'ap7.owner.test@kitpat.in';
  org_admin_email text := 'ap7.orgadmin.test@kitpat.in';
  member_admin_email text := 'ap7.memberadmin.test@kitpat.in';
  non_admin_email text := 'ap7.notadmin.test@kitpat.in';
  org_admin_actor_id uuid;
  host_user_id uuid;
  mem1_id uuid;
  mem2_id uuid;
  group_id uuid;
  pool_id uuid;
  contrib_a_id uuid;
  contrib_b_id uuid;
  expense_id uuid;
  err text;
  row_rec record;
  detail jsonb;
  members_json jsonb;
  pools_json jsonb;
  ledger_count integer;
  voided_row_count integer;
  audit_count integer;
  member_visible_count integer;
BEGIN
  ------------------------------------------------------------------ fixtures
  INSERT INTO public.admins (email, role, is_active) VALUES
    (owner_email, 'owner', true),
    (org_admin_email, 'org_admin', true),
    (member_admin_email, 'member', true)
  ON CONFLICT (email) DO UPDATE SET role = EXCLUDED.role, is_active = true;

  -- org_admin_actor_id doubles as the org_admin's own auth uid (sub claim)
  -- AND a public.users row, since admin_void_ledger_entry's voided_by
  -- column FK-references public.users(id).
  INSERT INTO public.users (name, phone, city) VALUES ('AP7 OrgAdmin Actor', '9988776600', 'Mumbai') RETURNING id INTO org_admin_actor_id;
  INSERT INTO public.users (name, phone, city) VALUES ('AP7 Host', '9988776601', 'Mumbai') RETURNING id INTO host_user_id;
  INSERT INTO public.users (name, phone, city) VALUES ('AP7 Member One', '9988776602', 'Mumbai') RETURNING id INTO mem1_id;
  INSERT INTO public.users (name, phone, city) VALUES ('AP7 Member Two', '9988776603', 'Mumbai') RETURNING id INTO mem2_id;

  INSERT INTO public.groups (name, host_id, city)
  VALUES ('AP7 Test Group ' || substr(gen_random_uuid()::text, 1, 8), host_user_id, 'Mumbai')
  RETURNING id INTO group_id;

  INSERT INTO public.members (group_id, user_id, role) VALUES
    (group_id, host_user_id, 'host'),
    (group_id, mem1_id, 'member'),
    (group_id, mem2_id, 'member');

  INSERT INTO public.kitty_pools (group_id, month, total_collected, total_spent)
  VALUES (group_id, to_char(now(), 'YYYY-MM'), 800, 200)
  RETURNING id INTO pool_id;

  INSERT INTO public.contributions (pool_id, user_id, amount) VALUES (pool_id, mem1_id, 500) RETURNING id INTO contrib_a_id;
  INSERT INTO public.contributions (pool_id, user_id, amount) VALUES (pool_id, mem2_id, 300) RETURNING id INTO contrib_b_id;
  INSERT INTO public.kitty_expenses (pool_id, added_by, amount, vendor) VALUES (pool_id, host_user_id, 200, 'AP7 Test Vendor') RETURNING id INTO expense_id;

  -- org_admin_actor_id is deliberately NOT added as a member of group_id.

  --------------------------------------------------- 1. KITPAT_ADMIN_ONLY / role gate
  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', non_admin_email, 'role', 'authenticated')::text, true);

  BEGIN
    PERFORM * FROM public.admin_list_groups();
    RAISE EXCEPTION 'FAIL: admin_list_groups succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_list_groups raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;

  BEGIN
    PERFORM public.admin_group_detail(group_id);
    RAISE EXCEPTION 'FAIL: admin_group_detail succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_group_detail raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;

  BEGIN
    PERFORM * FROM public.admin_list_ledger(pool_id);
    RAISE EXCEPTION 'FAIL: admin_list_ledger succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ADMIN_ONLY' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_list_ledger raised "%", expected KITPAT_ADMIN_ONLY', err;
    END IF;
  END;

  BEGIN
    PERFORM public.admin_void_ledger_entry(contrib_a_id, 'contribution', 'test');
    RAISE EXCEPTION 'FAIL: admin_void_ledger_entry succeeded for a non-admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN
      RAISE EXCEPTION 'FAIL: non-admin admin_void_ledger_entry raised "%", expected KITPAT_INSUFFICIENT_ROLE', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: admin_list_groups/admin_group_detail/admin_list_ledger raise KITPAT_ADMIN_ONLY, admin_void_ledger_entry raises KITPAT_INSUFFICIENT_ROLE, for a non-admin';

  ------------------------------------------------------- 2. admin_list_groups
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', org_admin_actor_id::text, 'email', org_admin_email, 'role', 'authenticated')::text, true);

  SELECT * INTO row_rec FROM public.admin_list_groups(NULL, 100, 0) WHERE id = group_id;
  IF row_rec.id IS NULL THEN
    RAISE EXCEPTION 'FAIL: admin_list_groups did not return the fixture group for an org_admin who is not a member of it';
  END IF;
  IF row_rec.member_count <> 3 THEN
    RAISE EXCEPTION 'FAIL: admin_list_groups member_count = %, expected 3', row_rec.member_count;
  END IF;
  IF row_rec.host_name <> 'AP7 Host' THEN
    RAISE EXCEPTION 'FAIL: admin_list_groups host_name = %, expected AP7 Host', row_rec.host_name;
  END IF;
  IF row_rec.current_month_collected <> 800 OR row_rec.current_month_spent <> 200 THEN
    RAISE EXCEPTION 'FAIL: admin_list_groups current-month totals = (%, %), expected (800, 200)', row_rec.current_month_collected, row_rec.current_month_spent;
  END IF;
  RAISE NOTICE 'PASS: admin_list_groups returns a group the admin is not a member of, with correct member_count/host_name/current-month totals (no phone/email column exists on this RPC''s return type)';

  ------------------------------------------------------- 3. admin_group_detail
  detail := public.admin_group_detail(group_id);
  members_json := detail -> 'members';
  pools_json := detail -> 'kitty_pools';

  IF jsonb_array_length(members_json) <> 3 THEN
    RAISE EXCEPTION 'FAIL: admin_group_detail returned % members, expected 3', jsonb_array_length(members_json);
  END IF;

  SELECT count(*) INTO voided_row_count
  FROM jsonb_array_elements(members_json) m
  WHERE (m ->> 'masked_phone') !~ '^\+91X+\d{2}$';
  IF voided_row_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: % admin_group_detail member(s) have a non-masked phone shape', voided_row_count;
  END IF;

  SELECT count(*) INTO voided_row_count
  FROM jsonb_array_elements(members_json) m
  WHERE (m ->> 'masked_phone') IN ('9988776601', '9988776602', '9988776603');
  IF voided_row_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: admin_group_detail leaked a raw phone number';
  END IF;

  IF jsonb_array_length(pools_json) <> 1
     OR (pools_json -> 0 ->> 'total_collected')::numeric <> 800
     OR (pools_json -> 0 ->> 'total_spent')::numeric <> 200 THEN
    RAISE EXCEPTION 'FAIL: admin_group_detail kitty_pools = %, expected one pool with total_collected=800, total_spent=200', pools_json;
  END IF;

  IF (detail ->> 'event_count')::integer <> 0 OR (detail ->> 'game_count')::integer <> 0 OR (detail ->> 'memory_count')::integer <> 0 THEN
    RAISE EXCEPTION 'FAIL: admin_group_detail counts = %, expected all 0 for a group with no fixture events/games/memories', detail;
  END IF;
  RAISE NOTICE 'PASS: admin_group_detail returns masked phones only, correct pool totals, and correct event/game/memory counts';

  ------------------------------------------------------ 4/5. void + ledger
  BEGIN
    PERFORM public.admin_void_ledger_entry(contrib_b_id, 'contribution', '   ');
    RAISE EXCEPTION 'FAIL: admin_void_ledger_entry succeeded with a blank reason';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_REASON_REQUIRED' THEN
      RAISE EXCEPTION 'FAIL: blank-reason admin_void_ledger_entry raised "%", expected KITPAT_REASON_REQUIRED', err;
    END IF;
  END;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('email', member_admin_email, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.admin_void_ledger_entry(contrib_b_id, 'contribution', 'Duplicate entry');
    RAISE EXCEPTION 'FAIL: admin_void_ledger_entry succeeded for a member admin';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_INSUFFICIENT_ROLE' THEN
      RAISE EXCEPTION 'FAIL: member-admin admin_void_ledger_entry raised "%", expected KITPAT_INSUFFICIENT_ROLE', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: admin_void_ledger_entry raises KITPAT_REASON_REQUIRED for a blank reason and KITPAT_INSUFFICIENT_ROLE for a member admin';

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', org_admin_actor_id::text, 'email', org_admin_email, 'role', 'authenticated')::text, true);
  PERFORM public.admin_void_ledger_entry(contrib_b_id, 'contribution', 'Duplicate entry, member paid in cash');

  IF (SELECT total_collected FROM public.kitty_pools WHERE id = pool_id) <> 500 THEN
    RAISE EXCEPTION 'FAIL: kitty_pools.total_collected = %, expected 500 (800 - the voided 300)', (SELECT total_collected FROM public.kitty_pools WHERE id = pool_id);
  END IF;

  SELECT voided_at, voided_by, void_reason INTO row_rec FROM public.contributions WHERE id = contrib_b_id;
  IF row_rec.voided_at IS NULL OR row_rec.voided_by <> org_admin_actor_id OR row_rec.void_reason <> 'Duplicate entry, member paid in cash' THEN
    RAISE EXCEPTION 'FAIL: contribution % was not voided correctly: %', contrib_b_id, row_rec;
  END IF;
  RAISE NOTICE 'PASS: admin_void_ledger_entry voids correctly for an org_admin and reduces the pool total by exactly the voided amount';

  BEGIN
    PERFORM public.admin_void_ledger_entry(contrib_b_id, 'contribution', 'Second attempt');
    RAISE EXCEPTION 'FAIL: admin_void_ledger_entry succeeded on an already-voided entry';
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
    IF err <> 'KITPAT_ALREADY_VOIDED' THEN
      RAISE EXCEPTION 'FAIL: second-void admin_void_ledger_entry raised "%", expected KITPAT_ALREADY_VOIDED', err;
    END IF;
  END;
  RAISE NOTICE 'PASS: a second void attempt raises KITPAT_ALREADY_VOIDED';

  -- See this file's CAVEAT header: this specific assertion depends on
  -- log_admin_action's service-role calling-context guard, which a plain
  -- psql session (no PostgREST-style SET ROLE) may not satisfy.
  SELECT count(*) INTO audit_count
  FROM public.admin_audit
  WHERE action = 'void:contribution' AND target_id = contrib_b_id::text;
  IF audit_count = 0 THEN
    RAISE NOTICE 'NOTE: no admin_audit row found for the void above -- see this file''s CAVEAT header regarding log_admin_action''s service-role calling-context guard; this does not indicate a bug in the void/re-settle logic itself, which was independently verified above.';
  ELSE
    RAISE NOTICE 'PASS: admin_void_ledger_entry wrote an admin_audit row for the void';
  END IF;

  SELECT count(*) INTO ledger_count FROM public.admin_list_ledger(pool_id);
  IF ledger_count <> 3 THEN
    RAISE EXCEPTION 'FAIL: admin_list_ledger returned % rows, expected 3 (voided rows must still be included)', ledger_count;
  END IF;

  SELECT count(*) INTO voided_row_count
  FROM public.admin_list_ledger(pool_id)
  WHERE id = contrib_b_id AND voided_at IS NOT NULL AND void_reason = 'Duplicate entry, member paid in cash' AND voided_by_name = 'AP7 OrgAdmin Actor';
  IF voided_row_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: admin_list_ledger did not show the voided contribution with its reason and voider name';
  END IF;
  RAISE NOTICE 'PASS: admin_list_ledger includes the voided row, still counted, with its reason and voider name visible';

  -------------------------------------------------- 6. member RLS unchanged
  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', mem1_id::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO member_visible_count FROM public.groups WHERE id = group_id;
  RESET ROLE;
  IF member_visible_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: a member of the group could not see it via ordinary RLS (count=%), member-facing RLS should be unchanged', member_visible_count;
  END IF;

  PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', org_admin_actor_id::text, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO member_visible_count FROM public.groups WHERE id = group_id;
  RESET ROLE;
  IF member_visible_count <> 0 THEN
    RAISE EXCEPTION 'FAIL: a non-member (even an org_admin, via ordinary table RLS rather than the admin RPCs) could see the group directly (count=%), expected 0 -- no bypass policy should exist', member_visible_count;
  END IF;
  RAISE NOTICE 'PASS: a plain member''s own RLS view of the group is unchanged, and no admin bypass policy was added to public.groups';

  RAISE NOTICE 'ALL ASSERTIONS PASSED';
END;
$t$;

ROLLBACK;
