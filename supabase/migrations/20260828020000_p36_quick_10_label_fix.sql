-- ---------------------------------------------------------------------------
-- P36: fix the misleading "Quick 10-Minute" label on tambola_variants
-- key='quick_10'.
--
-- 90 numbers at that variant's draw interval take ~15 minutes in practice,
-- not 10, so the display label and content.target_minutes were wrong. Only
-- the label is corrected here:
--   - tambola_variants.key stays 'quick_10' -- the frontend references this
--     key directly, so the identifier is untouched.
--   - tambola_variants.default_interval_seconds is untouched -- the pace was
--     fine, only the advertised duration was wrong.
--   - game_sessions.draw_interval_seconds (set per-session at creation time
--     from default_interval_seconds) is likewise untouched by this
--     migration; it was never wrong.
-- ---------------------------------------------------------------------------

UPDATE public.tambola_variants
SET
  display_name = 'Quick 15',
  config = jsonb_set(config, '{target_minutes}', to_jsonb(15))
WHERE key = 'quick_10';

-- Any game_theme_packs row(s) for this variant that still say "10-Minute" in
-- their display text get the same correction. This is a no-op if no such
-- row/text exists (e.g. the pack is seeded from tambola_variants alone) --
-- only the matching substring is swapped, every other column and every
-- other jsonb key is left exactly as-is.
UPDATE public.game_theme_packs
SET
  name = CASE WHEN name LIKE '%10-Minute%' THEN replace(name, '10-Minute', '15') ELSE name END,
  description = CASE WHEN description LIKE '%10-Minute%' THEN replace(description, '10-Minute', '15') ELSE description END
WHERE game_key = 'tambola'
  AND theme_key = 'quick_10'
  AND (name LIKE '%10-Minute%' OR description LIKE '%10-Minute%');
