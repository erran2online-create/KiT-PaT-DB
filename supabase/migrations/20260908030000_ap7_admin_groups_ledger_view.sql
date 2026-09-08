-- ---------------------------------------------------------------------------
-- AP7: let admins view any group's ledger and void a wrong entry with a
-- reason, fully audited -- without weakening member-facing RLS.
--
-- groups/members/kitty_pools/contributions/kitty_expenses/events keep their
-- existing member-scoped RLS untouched (an admin who isn't a member of a
-- group still sees nothing through ordinary table access). These four
-- SECURITY DEFINER RPCs are the only admin read/write path; no bypass
-- policy is added anywhere.
--
-- admin_void_ledger_entry mirrors void_contribution/void_kitty_expense
-- (P26) exactly: same voided_at/voided_by/void_reason columns, same
-- same-transaction pool re-settle by recomputing from non-voided rows, same
-- never-hard-delete guarantee, same KITPAT_NOT_FOUND/KITPAT_ALREADY_VOIDED
-- codes. It additionally requires a non-empty reason and an owner/org_admin
-- role, and audits via log_admin_action.
--
-- AP7.1 UPDATE -- confirmed against the live database: log_admin_action's
-- original guard --
--   current_setting('role', true) = 'service_role' OR auth.jwt()->>'role' = 'service_role'
-- -- is false for a SECURITY DEFINER function called directly with an
-- admin's own JWT: PostgREST sets role = 'authenticated' for that request,
-- and SECURITY DEFINER changes current_user (for privilege checks), never
-- the 'role' GUC. admin_void_ledger_entry's log_admin_action call below
-- would therefore RAISE KITPAT_ADMIN_ONLY and abort the whole void --
-- and AP2's already-merged admin_confirm_reveal has the identical bug on
-- its sensitive-reveal log. Section 0 below fixes the shared guard (the
-- one place this rule is defined) rather than working around it in either
-- caller: it now also accepts an already-verified active admin
-- (public.is_admin(), itself SECURITY DEFINER and checked against the
-- caller's own JWT email) as authorization to write an audit row, in
-- addition to the original service_role path. admin_confirm_reveal and
-- admin_void_ledger_entry themselves are unchanged -- fixing the shared
-- guard repairs both.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 0. log_admin_action -- widen the guard to ALSO accept an active admin,
--    not just service_role. Same signature, params, insert and return as
--    AP1's version; only the top IF condition gains an OR is_admin().
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_admin_action(
  p_action text,
  p_target_type text,
  p_target_id text,
  p_before jsonb,
  p_after jsonb,
  p_is_sensitive_reveal boolean DEFAULT false,
  p_revealed_field text DEFAULT NULL,
  p_revealed_subject text DEFAULT NULL,
  p_actor_admin_id uuid DEFAULT NULL,
  p_actor_email text DEFAULT NULL
) RETURNS public.admin_audit
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  caller_email text;
  caller_admin_id uuid;
  row_out public.admin_audit;
BEGIN
  IF NOT coalesce(
    current_setting('role', true) = 'service_role'
    OR (auth.jwt() ->> 'role') = 'service_role'
    OR public.is_admin(),
    false
  ) THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  IF p_actor_admin_id IS NOT NULL OR p_actor_email IS NOT NULL THEN
    caller_admin_id := p_actor_admin_id;
    caller_email := p_actor_email;
  ELSE
    caller_email := auth.jwt() ->> 'email';
    IF caller_email IS NOT NULL THEN
      SELECT id INTO caller_admin_id FROM public.admins WHERE email = caller_email;
    END IF;
  END IF;

  INSERT INTO public.admin_audit (
    actor_admin_id, actor_email, action, target_type, target_id,
    before, after, is_sensitive_reveal, revealed_field, revealed_subject
  ) VALUES (
    caller_admin_id, caller_email, p_action, p_target_type, p_target_id,
    p_before, p_after, coalesce(p_is_sensitive_reveal, false), p_revealed_field, p_revealed_subject
  ) RETURNING * INTO row_out;

  RETURN row_out;
END;
$$;

COMMENT ON FUNCTION public.log_admin_action(text, text, text, jsonb, jsonb, boolean, text, text, uuid, text) IS
  'service_role OR an already-active admin (checked via current_setting(''role'')/the caller''s JWT role claim, OR public.is_admin() against the caller''s own JWT email) may write an audit row. Inserts one admin_audit row. Actor is p_actor_admin_id/p_actor_email when explicitly given, else auto-detected from the caller''s own auth.jwt()->>''email''. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.log_admin_action(text, text, text, jsonb, jsonb, boolean, text, text, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_admin_action(text, text, text, jsonb, jsonb, boolean, text, text, uuid, text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 1. admin_list_groups(p_search, p_limit, p_offset)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_groups(
  p_search text DEFAULT NULL,
  p_limit int DEFAULT 50,
  p_offset int DEFAULT 0
) RETURNS TABLE (
  id uuid,
  name text,
  city text,
  created_at timestamptz,
  member_count bigint,
  host_name text,
  current_month_collected numeric(12,2),
  current_month_spent numeric(12,2),
  last_activity_at timestamptz
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
    g.id,
    g.name,
    g.city,
    g.created_at,
    (SELECT count(*) FROM public.members m WHERE m.group_id = g.id) AS member_count,
    h.name AS host_name,
    coalesce(cp.total_collected, 0) AS current_month_collected,
    coalesce(cp.total_spent, 0) AS current_month_spent,
    greatest(
      coalesce((SELECT max(e.created_at) FROM public.events e WHERE e.group_id = g.id), '-infinity'::timestamptz),
      coalesce((
        SELECT max(c.paid_at) FROM public.contributions c
        JOIN public.kitty_pools p ON p.id = c.pool_id
        WHERE p.group_id = g.id
      ), '-infinity'::timestamptz),
      coalesce((SELECT max(ma.created_at) FROM public.memory_artifacts ma WHERE ma.group_id = g.id), '-infinity'::timestamptz)
    ) AS last_activity_at
  FROM public.groups g
  LEFT JOIN public.users h ON h.id = g.host_id
  LEFT JOIN public.kitty_pools cp ON cp.group_id = g.id AND cp.month = to_char(now(), 'YYYY-MM')
  WHERE p_search IS NULL OR g.name ILIKE '%' || p_search || '%'
  ORDER BY g.created_at DESC
  LIMIT greatest(coalesce(p_limit, 50), 0)
  OFFSET greatest(coalesce(p_offset, 0), 0);
END;
$$;

COMMENT ON FUNCTION public.admin_list_groups(text, int, int) IS
  'Any active admin. Every group (optionally name-filtered) with member_count, host_name, the current calendar month''s kitty totals, and last_activity_at (latest of the group''s newest event/contribution/memory). Never a phone or email. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_groups(text, int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_groups(text, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. admin_group_detail(p_group_id)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_group_detail(p_group_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  grp public.groups;
  result jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'KITPAT_ADMIN_ONLY' USING ERRCODE = 'PT403';
  END IF;

  SELECT * INTO grp FROM public.groups WHERE id = p_group_id;
  IF grp.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  SELECT jsonb_build_object(
    'id', grp.id,
    'name', grp.name,
    'city', grp.city,
    'description', grp.description,
    'host_id', grp.host_id,
    'created_at', grp.created_at,
    'members', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'user_id', m.user_id,
          'name', u.name,
          'role', m.role,
          'joined_at', m.joined_at,
          'masked_phone', CASE WHEN u.phone IS NULL THEN NULL
            ELSE '+91' || repeat('X', greatest(length(u.phone) - 2, 0)) || right(u.phone, 2)
          END
        )
        ORDER BY m.joined_at
      )
      FROM public.members m
      LEFT JOIN public.users u ON u.id = m.user_id
      WHERE m.group_id = grp.id
    ), '[]'::jsonb),
    'kitty_pools', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'pool_id', p.id,
          'month', p.month,
          'total_collected', p.total_collected,
          'total_spent', p.total_spent,
          'balance', p.total_collected - p.total_spent
        )
        ORDER BY p.month DESC
      )
      FROM public.kitty_pools p
      WHERE p.group_id = grp.id
    ), '[]'::jsonb),
    'event_count', (SELECT count(*) FROM public.events e WHERE e.group_id = grp.id),
    'game_count', (SELECT count(*) FROM public.game_sessions gs WHERE gs.group_id = grp.id),
    'memory_count', (SELECT count(*) FROM public.memory_artifacts ma WHERE ma.group_id = grp.id)
  ) INTO result;

  RETURN result;
END;
$$;

COMMENT ON FUNCTION public.admin_group_detail(uuid) IS
  'Any active admin. One group''s full detail: the group row, its members (name/role/joined_at + masked phone, same +91X...NN rule as admin_list_users -- never raw), its kitty pools with totals, and event/game/memory counts. game_count is public.game_sessions (the group-linked tambola/game-lobby table), not the older event-scoped public.games. No raw contact details anywhere. Errors: KITPAT_ADMIN_ONLY / KITPAT_NOT_FOUND.';

REVOKE ALL ON FUNCTION public.admin_group_detail(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_group_detail(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. admin_list_ledger(p_pool_id) -- the dispute-resolution view: every
--    contribution and kitty_expense for the pool, INCLUDING voided rows,
--    clearly flagged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_ledger(p_pool_id uuid)
RETURNS TABLE (
  id uuid,
  kind text,
  amount numeric(12,2),
  label text,
  note text,
  created_at timestamptz,
  voided_at timestamptz,
  void_reason text,
  voided_by_name text
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
    c.id, 'contribution'::text, c.amount, u.name, c.note, c.paid_at, c.voided_at, c.void_reason, vb.name
  FROM public.contributions c
  LEFT JOIN public.users u ON u.id = c.user_id
  LEFT JOIN public.users vb ON vb.id = c.voided_by
  WHERE c.pool_id = p_pool_id

  UNION ALL

  SELECT
    e.id, 'expense'::text, e.amount, e.vendor, e.note, e.created_at, e.voided_at, e.void_reason, vb.name
  FROM public.kitty_expenses e
  LEFT JOIN public.users vb ON vb.id = e.voided_by
  WHERE e.pool_id = p_pool_id

  ORDER BY created_at DESC;
END;
$$;

COMMENT ON FUNCTION public.admin_list_ledger(uuid) IS
  'Any active admin. Every contribution and kitty_expense for p_pool_id, INCLUDING voided rows (voided_at/void_reason/voided_by_name make a voided row unmistakable) -- the dispute-resolution view. label is the contributing member''s name for a contribution, the vendor for an expense. Errors: KITPAT_ADMIN_ONLY.';

REVOKE ALL ON FUNCTION public.admin_list_ledger(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_ledger(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. admin_void_ledger_entry(p_entry_id, p_kind, p_reason) -- owner/org_admin
--    only, mandatory reason, mirrors void_contribution/void_kitty_expense
--    exactly (never hard-deletes, re-settles the pool total from non-voided
--    rows in the same transaction), then audits via log_admin_action.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_void_ledger_entry(
  p_entry_id uuid,
  p_kind text,
  p_reason text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  admin_uid uuid := auth.uid();
  caller_email text := auth.jwt() ->> 'email';
  caller_admin_id uuid;
  v_pool_id uuid;
  pool public.kitty_pools;
  trimmed_reason text;
  contrib public.contributions;
  expense public.kitty_expenses;
  before_row jsonb;
  after_row jsonb;
BEGIN
  IF NOT public.is_admin() OR public.admin_role() NOT IN ('owner', 'org_admin') THEN
    RAISE EXCEPTION 'KITPAT_INSUFFICIENT_ROLE' USING ERRCODE = 'PT403';
  END IF;

  IF p_kind IS NULL OR p_kind NOT IN ('contribution', 'expense') THEN
    RAISE EXCEPTION 'KITPAT_INVALID_KIND' USING ERRCODE = 'PT400';
  END IF;

  trimmed_reason := nullif(btrim(coalesce(p_reason, '')), '');
  IF trimmed_reason IS NULL THEN
    RAISE EXCEPTION 'KITPAT_REASON_REQUIRED' USING ERRCODE = 'PT400';
  END IF;

  SELECT id INTO caller_admin_id FROM public.admins WHERE email = caller_email AND is_active = true;

  IF p_kind = 'contribution' THEN
    SELECT c.pool_id INTO v_pool_id FROM public.contributions c WHERE c.id = p_entry_id;
  ELSE
    SELECT e.pool_id INTO v_pool_id FROM public.kitty_expenses e WHERE e.id = p_entry_id;
  END IF;

  IF v_pool_id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  -- Lock the pool before the ledger row, same order as void_contribution/
  -- void_kitty_expense and record_contribution/record_expense.
  SELECT * INTO pool FROM public.kitty_pools WHERE id = v_pool_id FOR UPDATE;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
  END IF;

  IF p_kind = 'contribution' THEN
    SELECT * INTO contrib FROM public.contributions WHERE id = p_entry_id FOR UPDATE;
    IF contrib.id IS NULL THEN
      RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
    END IF;
    IF contrib.voided_at IS NOT NULL THEN
      RAISE EXCEPTION 'KITPAT_ALREADY_VOIDED' USING ERRCODE = 'PT409';
    END IF;

    before_row := to_jsonb(contrib);

    UPDATE public.contributions c
    SET voided_at = now(), voided_by = admin_uid, void_reason = trimmed_reason
    WHERE c.id = contrib.id AND c.voided_at IS NULL
    RETURNING * INTO contrib;

    IF contrib.id IS NULL THEN
      RAISE EXCEPTION 'KITPAT_ALREADY_VOIDED' USING ERRCODE = 'PT409';
    END IF;

    UPDATE public.kitty_pools p
    SET total_collected = coalesce((
      SELECT sum(c.amount) FROM public.contributions c
      WHERE c.pool_id = p.id AND c.voided_at IS NULL
    ), 0)
    WHERE p.id = pool.id;

    after_row := to_jsonb(contrib);
  ELSE
    SELECT * INTO expense FROM public.kitty_expenses WHERE id = p_entry_id FOR UPDATE;
    IF expense.id IS NULL THEN
      RAISE EXCEPTION 'KITPAT_NOT_FOUND' USING ERRCODE = 'PT404';
    END IF;
    IF expense.voided_at IS NOT NULL THEN
      RAISE EXCEPTION 'KITPAT_ALREADY_VOIDED' USING ERRCODE = 'PT409';
    END IF;

    before_row := to_jsonb(expense);

    UPDATE public.kitty_expenses e
    SET voided_at = now(), voided_by = admin_uid, void_reason = trimmed_reason
    WHERE e.id = expense.id AND e.voided_at IS NULL
    RETURNING * INTO expense;

    IF expense.id IS NULL THEN
      RAISE EXCEPTION 'KITPAT_ALREADY_VOIDED' USING ERRCODE = 'PT409';
    END IF;

    UPDATE public.kitty_pools p
    SET total_spent = coalesce((
      SELECT sum(e.amount) FROM public.kitty_expenses e
      WHERE e.pool_id = p.id AND e.voided_at IS NULL
    ), 0)
    WHERE p.id = pool.id;

    after_row := to_jsonb(expense);
  END IF;

  PERFORM public.log_admin_action(
    'void:' || p_kind,
    p_kind,
    p_entry_id::text,
    before_row,
    after_row,
    false,
    NULL,
    NULL,
    caller_admin_id,
    caller_email
  );

  RETURN after_row;
END;
$$;

COMMENT ON FUNCTION public.admin_void_ledger_entry(uuid, text, text) IS
  'Owner/org_admin only (member admins rejected). Mirrors void_contribution/void_kitty_expense exactly: sets voided_at/voided_by/void_reason and re-settles the pool total from non-voided rows in the same transaction; never hard-deletes. p_reason is mandatory (trimmed non-empty). Audits via log_admin_action(''void:''||p_kind, ...) -- see section 0 above (AP7.1) for the log_admin_action guard fix that makes this call succeed when invoked directly with the admin''s own JWT. Errors: KITPAT_INSUFFICIENT_ROLE / KITPAT_INVALID_KIND / KITPAT_REASON_REQUIRED / KITPAT_NOT_FOUND / KITPAT_ALREADY_VOIDED.';

REVOKE ALL ON FUNCTION public.admin_void_ledger_entry(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_void_ledger_entry(uuid, text, text) TO authenticated, service_role;
