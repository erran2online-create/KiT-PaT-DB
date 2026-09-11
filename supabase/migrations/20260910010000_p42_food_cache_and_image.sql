-- ---------------------------------------------------------------------------
-- P42: food tracking cache + image input.
--
-- SCOPE CHANGE, recorded deliberately: P41 stated food tracking was
-- text-only and not a photo feature. That is superseded -- it now accepts
-- THREE inputs (typed text, a camera capture, or an uploaded image), all
-- three arriving at analyze-food as either a text description or an
-- already-uploaded Cloudinary image_url (a camera capture is just an
-- upload from the device camera rather than the gallery -- the same
-- image_url path). P41's own migration file
-- (20260909040000_p41_food_tracking.sql) is already applied to production
-- and is therefore never edited to reflect this -- its text-only framing
-- is superseded by this migration plus analyze-food/index.ts's own
-- updated header comment, not retroactively rewritten.
--
-- PART A -- cache. Repeated text lookups are wasteful and, worse,
-- inconsistent: two members typing the same dish should get the same
-- numbers. public.normalize_food_key(text) is the ONE place the
-- normalisation rule lives, called by both the cache lookup and the cache
-- write inside analyze-food, so they can never drift apart. Exact
-- normalised match only -- no stemming, no synonym matching.
--
-- PART B -- image input. The upload itself stays entirely outside this
-- function: the client uploads to Cloudinary via the existing
-- media-signature edge function (unchanged, not touched here) exactly as
-- memories do, and passes the resulting URL to analyze-food. No upload
-- path, no raw base64, no Supabase Storage bucket. Image lookups are
-- NEVER cached (every photo is different; a cache keyed on anything
-- derived from an image would serve wrong answers) -- food_cache is
-- therefore untouched by the image path entirely.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. normalize_food_key -- lowercase, strip everything except letters,
--    digits, decimal points and whitespace, collapse whitespace runs, trim.
--    IMMUTABLE: a pure function of its input, safe to index on if ever
--    needed later.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.normalize_food_key(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT btrim(
    regexp_replace(
      regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9.]+', ' ', 'g'),
      '\s+', ' ', 'g'
    )
  );
$$;

COMMENT ON FUNCTION public.normalize_food_key(text) IS
  'The one place food-cache key normalisation lives: lowercase, trim, collapse whitespace runs to one space, strip all punctuation except digits and decimal points. Exact match only -- no stemming or synonyms. Used identically by analyze-food''s cache lookup and cache write so they can never drift apart.';

REVOKE ALL ON FUNCTION public.normalize_food_key(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.normalize_food_key(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.normalize_food_key(text) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. food_cache -- service_role only (analyze-food). One example
--    description is kept per row for debugging; the cache key itself is
--    what's actually matched on.
-- ---------------------------------------------------------------------------
CREATE TABLE public.food_cache (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalized_key text NOT NULL UNIQUE,
  sample_description text NOT NULL,
  serving text,
  calories_kcal numeric,
  protein_g numeric,
  fat_g numeric,
  carbs_g numeric,
  ai_provider text NOT NULL,
  ai_model text NOT NULL,
  hit_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_hit_at timestamptz
);

COMMENT ON TABLE public.food_cache IS
  'Text-description -> macros cache, keyed on normalize_food_key(description || serving). NEVER populated by an image lookup -- every photo is different. service_role only (analyze-food): no client policy of any kind.';
COMMENT ON COLUMN public.food_cache.sample_description IS
  'One real example description that produced this key, kept for debugging -- not itself matched on.';

ALTER TABLE public.food_cache ENABLE ROW LEVEL SECURITY;
-- Deliberately zero policies: RLS default-denies every command for every
-- role that isn't exempt. service_role is exempt (its own role attribute)
-- and holds the explicit grant below; anon/authenticated get nothing.

REVOKE ALL ON public.food_cache FROM anon;
REVOKE ALL ON public.food_cache FROM authenticated;
GRANT ALL ON public.food_cache TO service_role;

-- ---------------------------------------------------------------------------
-- 3. ai_usage_log.input_kind -- lets text vs image spend be told apart
--    later (an image call costs roughly 10x a text call in input tokens).
--    Nullable: existing P41.1 rows predate this column and were all text.
-- ---------------------------------------------------------------------------
ALTER TABLE public.ai_usage_log
  ADD COLUMN IF NOT EXISTS input_kind text;

ALTER TABLE public.ai_usage_log
  DROP CONSTRAINT IF EXISTS ai_usage_log_input_kind_check;
ALTER TABLE public.ai_usage_log
  ADD CONSTRAINT ai_usage_log_input_kind_check
  CHECK (input_kind IS NULL OR input_kind IN ('text', 'image'));

COMMENT ON COLUMN public.ai_usage_log.input_kind IS
  'text or image -- which kind of input this AI call analyzed. NULL for rows written before this column existed. Image calls cost roughly 10x a text call in input tokens.';
