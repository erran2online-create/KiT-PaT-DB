-- P11: Party (events) fields surfaced by L9 — title, language, cover, note, kitty link.
-- groups has default_locale (not default_language), so events.language stays nullable
-- with no automatic default from groups.

ALTER TABLE public.events
  ADD COLUMN IF NOT EXISTS title text,
  ADD COLUMN IF NOT EXISTS language text,
  ADD COLUMN IF NOT EXISTS cover_url text,
  ADD COLUMN IF NOT EXISTS note text,
  ADD COLUMN IF NOT EXISTS kitty_pool_id uuid REFERENCES public.kitty_pools(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_events_kitty_pool ON public.events (kitty_pool_id)
  WHERE kitty_pool_id IS NOT NULL;

COMMENT ON COLUMN public.events.title IS 'Display title for the party (distinct from theme slug).';
COMMENT ON COLUMN public.events.language IS 'Party language preference (free text). No default — groups use default_locale, not default_language.';
COMMENT ON COLUMN public.events.cover_url IS 'Cloudinary (or other) cover image URL.';
COMMENT ON COLUMN public.events.note IS 'Host note / description for the party.';
COMMENT ON COLUMN public.events.kitty_pool_id IS 'Optional link to the kitty pool funding this party.';

-- Pool must belong to the same group as the event when set.
CREATE OR REPLACE FUNCTION public.events_kitty_pool_same_group()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
begin
  if NEW.kitty_pool_id is null then
    return NEW;
  end if;
  if not exists (
    select 1 from public.kitty_pools kp
    where kp.id = NEW.kitty_pool_id and kp.group_id = NEW.group_id
  ) then
    raise exception 'kitty_pool_id must belong to the same group as the event';
  end if;
  return NEW;
end;
$$;

DROP TRIGGER IF EXISTS events_kitty_pool_same_group ON public.events;
CREATE TRIGGER events_kitty_pool_same_group
  BEFORE INSERT OR UPDATE OF kitty_pool_id, group_id ON public.events
  FOR EACH ROW EXECUTE FUNCTION public.events_kitty_pool_same_group();
