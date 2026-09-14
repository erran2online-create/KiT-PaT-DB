-- ---------------------------------------------------------------------------
-- P45.2/P45.3: seed the 3 missing analytics_event_catalog rows the
-- ingest-event edge function (P45) needs. Without these, invite_redeemed,
-- contribution_recorded and client_error are silently dropped forever by
-- ingest-event's "unknown event_name: drop silently" behaviour -- exactly
-- the gap flagged (not guessed around) in that PR.
--
-- public.analytics_event_catalog's shape was read in full from
-- 20260801140136_remote_schema.sql before writing this: event_name (PK),
-- category, description, required_properties text[], contains_pii boolean,
-- created_at. No migration in this repo seeds this table (grepping every
-- migration for "INSERT INTO.*analytics_event_catalog" returns nothing,
-- same situation as feature_flags' pre-existing rows) -- the live category
-- taxonomy below was supplied directly by the user after verifying it live,
-- not read from this repo, since this repo has no record of it:
--
--   activation : signup_completed
--   games      : game_completed, game_session_created, game_started,
--                tambola_claim
--   group      : group_created, member_joined
--   memory     : media_uploaded, memory_artifact_ready
--   party      : party_created, rsvp_submitted
--   retention  : next_party_created_from_memory
--   virality   : invite_shared, memory_shared
--
-- (14 rows total, all contains_pii = false.)
--
-- Of the 9 event names ingest-event's contract requires, 6 already exist
-- (signup_completed, group_created, invite_shared, party_created,
-- game_started, game_completed) and are left untouched here. This
-- migration adds exactly the 3 that don't:
--
--   invite_redeemed        category 'virality' -- matches invite_shared,
--                           the existing row for the other half of the
--                           same invite flow.
--   contribution_recorded  category 'kitty' -- NEW. Confirmed (by the
--                           user, against the live 14 rows) that no money/
--                           kitty category exists in the seven above.
--                           'kitty' is the product's own word for the pool
--                           (public.kitty_pools, public.kitty_expenses)
--                           and does not collide with any existing name.
--   client_error            category 'diagnostics' -- NEW. No existing
--                           category fits an uncaught-render-error event;
--                           confirmed no collision with the seven above.
--
-- Two new categories introduced: kitty, diagnostics. The full category set
-- after this migration is exactly:
--   activation, games, group, memory, party, retention, virality, kitty,
--   diagnostics
--
-- ON CONFLICT (event_name) DO NOTHING: the existing 14 rows, whatever
-- their exact description/required_properties/created_at, are never
-- touched by this migration re-running.
-- ---------------------------------------------------------------------------

INSERT INTO public.analytics_event_catalog (event_name, category, description, required_properties, contains_pii)
VALUES
  ('invite_redeemed', 'virality',
   'Invite link opened and redeemed into a group',
   ARRAY['group_id', 'channel'], false),
  ('contribution_recorded', 'kitty',
   'A member records a kitty contribution. recorded_for_self distinguishes a member marking her own payment from the host recording for someone else.',
   ARRAY['group_id', 'pool_id', 'recorded_for_self'], false),
  ('client_error', 'diagnostics',
   'Uncaught render error in the member app. Carries the error boundary name, message and stack only -- never user data.',
   ARRAY['boundary'], false)
ON CONFLICT (event_name) DO NOTHING;
