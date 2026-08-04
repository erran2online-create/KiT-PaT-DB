-- P8: record_media — persist Cloudinary upload metadata for group/event members.
-- Matches generate_party_recap photo_ids (media.event_id + photo/image).

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
  p_caption text DEFAULT NULL
) RETURNS public.media
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
declare
  uid uuid := auth.uid();
  ev public.events;
  row public.media;
  pub_id text := trim(coalesce(p_cloudinary_public_id, ''));
  asset text;
begin
  if uid is null then
    raise exception 'Authentication required';
  end if;
  if p_group_id is null or pub_id = '' then
    raise exception 'group_id and cloudinary_public_id are required';
  end if;
  if p_resource_type not in ('image', 'video') then
    raise exception 'resource_type must be image or video';
  end if;
  if not public.is_group_member(p_group_id, uid)
     and not public.is_group_host(p_group_id, uid) then
    raise exception 'Group membership required';
  end if;

  if p_event_id is not null then
    select * into ev from public.events where id = p_event_id;
    if ev.id is null then
      raise exception 'Event not found';
    end if;
    if ev.group_id is distinct from p_group_id then
      raise exception 'Event does not belong to group';
    end if;
  end if;

  asset := p_resource_type;

  select * into row from public.media where cloudinary_public_id = pub_id;
  if row.id is not null then
    -- Idempotent re-record of the same Cloudinary asset
    update public.media set
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
      processing_status = 'ready'
    where id = row.id
    returning * into row;
    return row;
  end if;

  insert into public.media (
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
    metadata
  ) values (
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
    jsonb_build_object('source', 'record_media')
  )
  returning * into row;

  return row;
end;
$$;

COMMENT ON FUNCTION public.record_media(uuid, text, text, uuid, text, text, bigint, integer, integer, numeric, text, text) IS
  'Member/host: insert media row after Cloudinary upload; links group/event for party recap photo_ids.';

REVOKE ALL ON FUNCTION public.record_media(uuid, text, text, uuid, text, text, bigint, integer, integer, numeric, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_media(uuid, text, text, uuid, text, text, bigint, integer, integer, numeric, text, text) TO authenticated, service_role;
