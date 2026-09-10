-- ---------------------------------------------------------------------------
-- AP10: let an admin attach an optional custom image to a badge, as an
-- alternative to the emoji.
--
-- DECISION (made explicitly, not invented here): the Cloudinary fields
-- live directly on badge_definitions, NOT as a public.media row, and NOT
-- in a Supabase Storage bucket (the project has zero buckets; media in
-- this app is signed server-side via the media-signature edge function
-- and goes to Cloudinary).
--
-- Why not a media row -- verified against the live database: media.
-- group_id is nullable, but media's RLS read policy is
--   media_read_members ... USING (is_group_member(group_id, auth.uid())
--                            OR is_group_host(group_id, auth.uid()))
-- With group_id NULL, both sides evaluate false for every caller -- a
-- group-less media row is invisible to every member, so a badge image
-- stored there would never render. record_media() independently
-- hard-requires a non-null p_group_id and group membership/host status in
-- its own logic, so there is no existing insert path for a group-less row
-- either. Rewriting media_read_members to add a group-less/public branch
-- would put every party photo and payment receipt's access rule at risk
-- for the sake of a badge icon -- far too much blast radius. Badges are
-- global catalogue content, not user media: badge_definitions is already
-- world-readable via badges_public_read (qual: true), so the image
-- belongs on that same catalogue row.
--
-- Upload flow: the signed Cloudinary upload still goes through the
-- existing media-signature edge function, unchanged. Only the resulting
-- identifiers (public id, URL, format, dimensions) land on
-- badge_definitions instead of a media row. No new edge function.
--
-- Write path: badge_definitions has been in admin-write's PK_COLUMN map
-- and admin_can_write's allow-list since AP1 (org_admin+owner, audited
-- via log_admin_action) -- the existing admin-write call already accepts
-- an arbitrary payload for any allow-listed table, so it covers these
-- five new columns the moment they exist. No new RPC, no edit to
-- admin-write/index.ts or admin_can_write.
--
-- Additive only: five new, all-nullable columns. Nothing dropped,
-- nothing renamed. emoji stays as-is and remains the default whenever
-- image_cloudinary_public_id is null. badges_public_read (`USING (true)`)
-- is untouched -- the member app's badge read is unaffected.
-- ---------------------------------------------------------------------------

ALTER TABLE public.badge_definitions
  ADD COLUMN IF NOT EXISTS image_cloudinary_public_id text,
  ADD COLUMN IF NOT EXISTS image_url text,
  ADD COLUMN IF NOT EXISTS image_format text,
  ADD COLUMN IF NOT EXISTS image_width integer,
  ADD COLUMN IF NOT EXISTS image_height integer;

COMMENT ON COLUMN public.badge_definitions.image_cloudinary_public_id IS
  'Optional custom badge image (Cloudinary public id), an alternative to emoji. NULL means "use emoji" -- the member-facing default. Signed via the existing media-signature edge function; admin-editable through the existing AP1 admin-write path (no new write path added for this).';
COMMENT ON COLUMN public.badge_definitions.image_url IS
  'Cloudinary delivery URL for image_cloudinary_public_id. NULL when no custom image is set.';
COMMENT ON COLUMN public.badge_definitions.image_format IS
  'Cloudinary asset format (e.g. png, webp) for image_cloudinary_public_id. NULL when no custom image is set.';
COMMENT ON COLUMN public.badge_definitions.image_width IS
  'Pixel width of the custom badge image. NULL when no custom image is set.';
COMMENT ON COLUMN public.badge_definitions.image_height IS
  'Pixel height of the custom badge image. NULL when no custom image is set.';
