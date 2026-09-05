-- ---------------------------------------------------------------------------
-- P40: lock down public.game_events client grants (security fix).
--
-- Correction of the original ask: "session_events" is NOT a table -- it is
-- a compatibility VIEW over public.game_events, added in
-- 20260803110000_tambola_celebration_broadcasts.sql, already SELECT-only
-- to authenticated/service_role (anon was never granted anything on the
-- view). The real object to fix is the underlying table, public.game_events.
--
-- Live state confirmed (not re-derived here): game_events already has RLS
-- ENABLED, with one existing SELECT policy ("group members view game
-- events"). But anon and authenticated both still hold DELETE, INSERT,
-- UPDATE, TRUNCATE, REFERENCES, TRIGGER, SELECT at the table-grant level.
-- TRUNCATE is not row-scoped at all -- it bypasses RLS entirely -- so any
-- anon or authenticated client can currently wipe the entire game event
-- log for every group. INSERT/UPDATE/DELETE are already blocked in
-- practice by RLS (no permissive policy exists for those commands), but
-- the grants themselves are needless excess and are revoked here too, for
-- the same least-privilege reason every other game table follows.
--
-- The engine writes to game_events via SECURITY DEFINER RPCs (owned by
-- postgres, the table owner), which bypass RLS by default -- revoking
-- these client grants does not touch that path. This migration does not
-- modify any function.
--
-- public.session_events (the view) is left exactly as-is, per its own
-- design ("do NOT create a duplicate session_events table; expose a
-- compatibility view instead") -- it continues to read straight through to
-- game_events and needs no grant/definition change here.
-- ---------------------------------------------------------------------------

-- 1 & 2. Revoke excess/write grants. authenticated keeps SELECT only; anon
-- keeps nothing.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.game_events FROM authenticated;
REVOKE ALL ON public.game_events FROM anon;

-- 3. Re-affirm the intended read grant explicitly (RLS + the policy below
-- then decide which rows are actually visible).
GRANT SELECT ON public.game_events TO authenticated;

-- 4. Existing policy only checked is_group_member, not is_group_host, so a
-- host who isn't separately enrolled as a members row could be denied read
-- access to their own session's log. Replaced (not weakened -- this only
-- adds host coverage) to match the is_group_member OR is_group_host shape
-- used elsewhere in this schema (e.g. "group members view memory
-- artifacts"). RLS was already enabled on this table; no ALTER TABLE
-- needed.
DROP POLICY IF EXISTS "group members view game events" ON public.game_events;

CREATE POLICY "group members view game events" ON public.game_events
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.game_sessions s
      WHERE s.id = game_events.session_id
        AND (public.is_group_member(s.group_id, auth.uid()) OR public.is_group_host(s.group_id, auth.uid()))
    )
  );
