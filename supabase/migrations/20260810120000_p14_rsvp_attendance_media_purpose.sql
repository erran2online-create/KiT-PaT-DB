-- P14: RSVP "Can't Make It", attendance roster for all members, media.purpose
--
-- 1) Frontend upserts rsvp.status = 'no' (RSVP_STATUSES). Check constraint only
--    allowed going|maybe|not_going → 23514 → "We couldn't save your RSVP".
--    Unique (event_id, user_id) already exists; keep/ensure it for upserts.
-- 2) Host can UPDATE attendance for others but INSERT was self-only, so first
--    "mark present" for another member failed RLS. List all group members
--    (not RSVP-filtered) via list_event_attendance_roster.
-- 3) media.purpose distinguishes Kitty receipt uploads from Memories photos.

-- ---------------------------------------------------------------------------
-- 1. RSVP: accept frontend 'no' + ensure unique + host may insert own row
-- ---------------------------------------------------------------------------
ALTER TABLE public.rsvp DROP CONSTRAINT IF EXISTS rsvp_status_check;
ALTER TABLE public.rsvp
  ADD CONSTRAINT rsvp_status_check
  CHECK (
    status IS NULL
    OR status = ANY (ARRAY['going'::text, 'maybe'::text, 'not_going'::text, 'no'::text])
  );

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.rsvp'::regclass
      AND conname = 'rsvp_event_id_user_id_key'
  ) THEN
    ALTER TABLE public.rsvp
      ADD CONSTRAINT rsvp_event_id_user_id_key UNIQUE (event_id, user_id);
  END IF;
END $$;

DROP POLICY IF EXISTS rsvp_insert_own ON public.rsvp;
CREATE POLICY rsvp_insert_own ON public.rsvp
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1
      FROM public.events e
      WHERE e.id = rsvp.event_id
        AND (
          public.is_group_member(e.group_id, (SELECT auth.uid()))
          OR public.is_group_host(e.group_id, (SELECT auth.uid()))
        )
    )
  );

-- ---------------------------------------------------------------------------
-- 2. Attendance: host may insert for any group member; roster RPC
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS "host inserts attendance" ON public.attendance;
CREATE POLICY "host inserts attendance" ON public.attendance
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.events e
      WHERE e.id = attendance.event_id
        AND public.is_group_host(e.group_id, (SELECT auth.uid()))
        AND (
          public.is_group_member(e.group_id, attendance.user_id)
          OR public.is_group_host(e.group_id, attendance.user_id)
        )
    )
  );

-- Also allow self check-in for hosts who are on the group (member OR host_id).
DROP POLICY IF EXISTS "self check in" ON public.attendance;
CREATE POLICY "self check in" ON public.attendance
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = (SELECT auth.uid())
    AND EXISTS (
      SELECT 1
      FROM public.events e
      WHERE e.id = attendance.event_id
        AND (
          public.is_group_member(e.group_id, (SELECT auth.uid()))
          OR public.is_group_host(e.group_id, (SELECT auth.uid()))
        )
    )
  );

CREATE OR REPLACE FUNCTION public.list_event_attendance_roster(p_event_id uuid)
RETURNS TABLE (
  user_id uuid,
  member_role text,
  display_name text,
  rsvp_status text,
  checked_in_at timestamptz,
  attended boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  gid uuid;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;

  SELECT e.group_id INTO gid FROM public.events e WHERE e.id = p_event_id;
  IF gid IS NULL THEN
    RAISE EXCEPTION 'Event not found';
  END IF;
  IF NOT public.is_group_member(gid, uid) AND NOT public.is_group_host(gid, uid) THEN
    RAISE EXCEPTION 'Group membership required';
  END IF;

  -- ALL joined members, regardless of RSVP (going / maybe / no / none).
  RETURN QUERY
  SELECT
    m.user_id,
    m.role,
    u.name,
    r.status,
    a.checked_in_at,
    (a.id IS NOT NULL) AS attended
  FROM public.members m
  LEFT JOIN public.users u ON u.id = m.user_id
  LEFT JOIN public.rsvp r
    ON r.event_id = p_event_id AND r.user_id = m.user_id
  LEFT JOIN public.attendance a
    ON a.event_id = p_event_id AND a.user_id = m.user_id
  WHERE m.group_id = gid
  ORDER BY
    CASE WHEN m.role IN ('host', 'co-host') THEN 0 ELSE 1 END,
    COALESCE(u.name, m.user_id::text);
END;
$$;

COMMENT ON FUNCTION public.list_event_attendance_roster(uuid) IS
  'All group members for an event with RSVP + attendance. Never filters out not_going/no.';

REVOKE ALL ON FUNCTION public.list_event_attendance_roster(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_event_attendance_roster(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. media.purpose + record_media + tag receipts on kitty paths
-- ---------------------------------------------------------------------------
ALTER TABLE public.media
  ADD COLUMN IF NOT EXISTS purpose text;

UPDATE public.media
SET purpose = 'memory'
WHERE purpose IS NULL;

ALTER TABLE public.media
  ALTER COLUMN purpose SET DEFAULT 'memory';

ALTER TABLE public.media
  ALTER COLUMN purpose SET NOT NULL;

ALTER TABLE public.media DROP CONSTRAINT IF EXISTS media_purpose_check;
ALTER TABLE public.media
  ADD CONSTRAINT media_purpose_check
  CHECK (purpose = ANY (ARRAY['memory'::text, 'receipt'::text]));

COMMENT ON COLUMN public.media.purpose IS
  'Upload category: memory (party photos) vs receipt (Kitty Balance / OCR bills).';

-- Backfill: anything already linked as a receipt → purpose=receipt
UPDATE public.media m
SET purpose = 'receipt'
WHERE m.id IN (
  SELECT c.receipt_media_id
  FROM public.contributions c
  WHERE c.receipt_media_id IS NOT NULL
  UNION
  SELECT ke.receipt_media_id
  FROM public.kitty_expenses ke
  WHERE ke.receipt_media_id IS NOT NULL
);

DROP FUNCTION IF EXISTS public.record_media(
  uuid, text, text, uuid, text, text, bigint, integer, integer, numeric, text, text
);

CREATE OR REPLACE FUNCTION public.record_media(
  p_group_id uuid,
  p_cloudinary_public_id text,
  p_resource_type text,
  p_event_id uuid DEFAULT NULL,
  p_cloudinary_url text DEFAULT NULL,
  p_format text DEFAULT NULL,
  p_bytes bigint DEFAULT NULL,
  p_width integer DEFAULT NULL,
  p_height integer DEFAULT NULL,
  p_duration_seconds numeric DEFAULT NULL,
  p_thumbnail_url text DEFAULT NULL,
  p_caption text DEFAULT NULL,
  p_purpose text DEFAULT 'memory'
) RETURNS public.media
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  ev public.events;
  row public.media;
  pub_id text := trim(coalesce(p_cloudinary_public_id, ''));
  asset text;
  purpose_norm text := lower(trim(coalesce(p_purpose, 'memory')));
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_group_id IS NULL OR pub_id = '' THEN
    RAISE EXCEPTION 'group_id and cloudinary_public_id are required';
  END IF;
  IF p_resource_type NOT IN ('image', 'video') THEN
    RAISE EXCEPTION 'resource_type must be image or video';
  END IF;
  IF purpose_norm NOT IN ('memory', 'receipt') THEN
    RAISE EXCEPTION 'purpose must be memory or receipt';
  END IF;
  IF NOT public.is_group_member(p_group_id, uid)
     AND NOT public.is_group_host(p_group_id, uid) THEN
    RAISE EXCEPTION 'Group membership required';
  END IF;

  IF p_event_id IS NOT NULL THEN
    SELECT * INTO ev FROM public.events WHERE id = p_event_id;
    IF ev.id IS NULL THEN
      RAISE EXCEPTION 'Event not found';
    END IF;
    IF ev.group_id IS DISTINCT FROM p_group_id THEN
      RAISE EXCEPTION 'Event does not belong to group';
    END IF;
  END IF;

  asset := p_resource_type;

  SELECT * INTO row FROM public.media WHERE cloudinary_public_id = pub_id;
  IF row.id IS NOT NULL THEN
    UPDATE public.media SET
      event_id = coalesce(p_event_id, event_id),
      group_id = p_group_id,
      cloudinary_url = coalesce(p_cloudinary_url, cloudinary_url),
      thumbnail_url = coalesce(p_thumbnail_url, thumbnail_url),
      format = coalesce(p_format, format),
      bytes = coalesce(p_bytes, bytes),
      width = coalesce(p_width, width),
      height = coalesce(p_height, height),
      duration_seconds = coalesce(p_duration_seconds, duration_seconds),
      caption = coalesce(p_caption, caption),
      asset_type = asset,
      resource_type = p_resource_type,
      media_type = 'photo',
      processing_status = 'ready',
      purpose = purpose_norm
    WHERE id = row.id
    RETURNING * INTO row;
    RETURN row;
  END IF;

  INSERT INTO public.media (
    event_id,
    group_id,
    uploader_id,
    cloudinary_url,
    cloudinary_public_id,
    media_type,
    caption,
    asset_type,
    resource_type,
    format,
    bytes,
    width,
    height,
    duration_seconds,
    thumbnail_url,
    moderation_status,
    processing_status,
    purpose,
    metadata
  ) VALUES (
    p_event_id,
    p_group_id,
    uid,
    p_cloudinary_url,
    pub_id,
    'photo',
    p_caption,
    asset,
    p_resource_type,
    p_format,
    p_bytes,
    p_width,
    p_height,
    p_duration_seconds,
    p_thumbnail_url,
    'approved',
    'ready',
    purpose_norm,
    jsonb_build_object('source', 'record_media')
  )
  RETURNING * INTO row;

  RETURN row;
END;
$$;

COMMENT ON FUNCTION public.record_media(
  uuid, text, text, uuid, text, text, bigint, integer, integer, numeric, text, text, text
) IS
  'Member/host: insert media after Cloudinary upload. p_purpose defaults to memory; pass receipt for Kitty bills.';

REVOKE ALL ON FUNCTION public.record_media(
  uuid, text, text, uuid, text, text, bigint, integer, integer, numeric, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_media(
  uuid, text, text, uuid, text, text, bigint, integer, integer, numeric, text, text, text
) TO authenticated, service_role;

-- Tag linked receipt media whenever kitty ledger paths attach it.
CREATE OR REPLACE FUNCTION public.tag_media_as_receipt(p_media_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF p_media_id IS NULL THEN
    RETURN;
  END IF;
  UPDATE public.media
  SET purpose = 'receipt'
  WHERE id = p_media_id
    AND purpose IS DISTINCT FROM 'receipt';
END;
$$;

REVOKE ALL ON FUNCTION public.tag_media_as_receipt(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tag_media_as_receipt(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.record_expense(
  p_pool_id uuid,
  p_amount integer,
  p_vendor text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_receipt_media_id uuid DEFAULT NULL,
  p_note text DEFAULT NULL
) RETURNS public.kitty_expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  pool public.kitty_pools;
  exp public.kitty_expenses;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = p_pool_id FOR UPDATE;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'Pool not found';
  END IF;
  IF NOT public.is_group_host(pool.group_id, uid) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;

  INSERT INTO public.kitty_expenses (
    pool_id, added_by, amount, vendor, category, receipt_media_id, note
  ) VALUES (
    p_pool_id, uid, p_amount, p_vendor, p_category, p_receipt_media_id, p_note
  ) RETURNING * INTO exp;

  UPDATE public.kitty_pools
  SET total_spent = total_spent + p_amount
  WHERE id = p_pool_id;

  PERFORM public.tag_media_as_receipt(p_receipt_media_id);

  RETURN exp;
END;
$$;

CREATE OR REPLACE FUNCTION public.record_contribution(
  p_pool_id uuid,
  p_user_id uuid,
  p_amount numeric,
  p_method text DEFAULT NULL,
  p_note text DEFAULT NULL,
  p_receipt_media_id uuid DEFAULT NULL
) RETURNS public.contributions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  pool public.kitty_pools;
  contrib public.contributions;
  amount_int integer;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;

  amount_int := round(p_amount)::integer;
  IF amount_int <= 0 THEN
    RAISE EXCEPTION 'Amount must be positive';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = p_pool_id FOR UPDATE;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'Pool not found';
  END IF;
  IF NOT public.is_group_host(pool.group_id, uid) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;
  IF NOT public.is_group_member(pool.group_id, p_user_id)
     AND NOT public.is_group_host(pool.group_id, p_user_id) THEN
    RAISE EXCEPTION 'User is not a group member';
  END IF;

  INSERT INTO public.contributions (
    pool_id, user_id, amount, method, paid_at, receipt_media_id, note
  ) VALUES (
    p_pool_id, p_user_id, amount_int, p_method, now(), p_receipt_media_id, p_note
  )
  RETURNING * INTO contrib;

  UPDATE public.kitty_pools
  SET total_collected = total_collected + amount_int
  WHERE id = p_pool_id;

  PERFORM public.tag_media_as_receipt(p_receipt_media_id);

  RETURN contrib;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_ocr_expense(
  p_pool_id uuid,
  p_ocr_result jsonb DEFAULT '{}'::jsonb,
  p_confirmed_amount numeric DEFAULT NULL,
  p_confirmed_vendor text DEFAULT NULL,
  p_confirmed_category text DEFAULT NULL,
  p_receipt_media_id uuid DEFAULT NULL
) RETURNS public.kitty_expenses
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  uid uuid := auth.uid();
  pool public.kitty_pools;
  ocr jsonb := coalesce(p_ocr_result, '{}'::jsonb);
  amount_int integer;
  exp public.kitty_expenses;
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF jsonb_typeof(ocr) <> 'object' THEN
    RAISE EXCEPTION 'OCR result must be a JSON object';
  END IF;
  IF p_confirmed_amount IS NULL OR p_confirmed_amount <= 0 THEN
    RAISE EXCEPTION 'Confirmed amount must be positive';
  END IF;

  amount_int := round(p_confirmed_amount)::integer;
  IF amount_int <= 0 THEN
    RAISE EXCEPTION 'Confirmed amount must be positive';
  END IF;

  SELECT * INTO pool FROM public.kitty_pools WHERE id = p_pool_id;
  IF pool.id IS NULL THEN
    RAISE EXCEPTION 'Pool not found';
  END IF;
  IF NOT public.is_group_host(pool.group_id, uid) THEN
    RAISE EXCEPTION 'Host access required';
  END IF;

  -- Tag before ledger write so even a failed expense leave receipt marked.
  PERFORM public.tag_media_as_receipt(p_receipt_media_id);

  exp := public.record_expense(
    p_pool_id,
    amount_int,
    p_confirmed_vendor,
    p_confirmed_category,
    p_receipt_media_id,
    'ocr_confirmed'
  );

  RETURN exp;
END;
$$;

COMMENT ON FUNCTION public.confirm_ocr_expense(uuid, jsonb, numeric, text, text, uuid) IS
  'OCR→kitty_expenses path. Tags p_receipt_media_id as purpose=receipt automatically.';
