-- P6: Additive group profile fields for frontend (photo, type, city, vibe).
-- invite_code already exists (unique, default substr(md5(random()::text), 1, 8)).

ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS photo_url text,
  ADD COLUMN IF NOT EXISTS group_type text,
  ADD COLUMN IF NOT EXISTS city text,
  ADD COLUMN IF NOT EXISTS vibe text;

DO $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'groups_vibe_check'
      and conrelid = 'public.groups'::regclass
  ) then
    alter table public.groups
      add constraint groups_vibe_check
      check (
        vibe is null
        or vibe = any (array[
          'classy'::text,
          'fun'::text,
          'filmy'::text,
          'traditional'::text,
          'warm'::text,
          'competitive'::text,
          'custom'::text
        ])
      );
  end if;
end
$$;

COMMENT ON COLUMN public.groups.photo_url IS 'Optional Cloudinary (or similar) group photo URL.';
COMMENT ON COLUMN public.groups.group_type IS 'Optional frontend group type label.';
COMMENT ON COLUMN public.groups.city IS 'Optional group city.';
COMMENT ON COLUMN public.groups.vibe IS 'Optional vibe: classy|fun|filmy|traditional|warm|competitive|custom.';

-- Groups RLS policies call is_group_member / is_group_host as the invoking role.
-- Without EXECUTE for authenticated, SELECT/UPDATE WITH representation fails with 42501.
GRANT EXECUTE ON FUNCTION public.is_group_member(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_group_host(uuid, uuid) TO authenticated;
