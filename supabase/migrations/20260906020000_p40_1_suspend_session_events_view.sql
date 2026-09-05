-- ---------------------------------------------------------------------------
-- P40.1: suspend all client access to public.session_events.
--
-- Separate from P40 (20260906010000), which locks down public.game_events
-- itself and does not touch this view. This migration handles the view.
--
-- Live state confirmed: public.session_events (a compatibility VIEW over
-- game_events, from 20260803110000_tambola_celebration_broadcasts.sql) is
-- referenced nowhere -- 0 hits in the current frontend, 0 in n8n, and in
-- this repo the only mentions are inside the migration that created it.
-- But production has drifted: anon AND authenticated currently hold
-- SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER on it, and
-- it has no security_invoker set, so it runs as its owner and bypasses
-- game_events' RLS entirely -- exactly the confidentiality gap flagged
-- (but left unfixed, "leave the view as-is") in the P40 test notes.
--
-- Since nothing depends on it, the simplest correct fix is to suspend
-- client access altogether rather than try to make it safely re-readable:
-- keep the view (in case of future use), but grant nothing to anon or
-- authenticated, and turn on security_invoker so that if it is ever
-- reactivated, it honours game_events' RLS instead of bypassing it as the
-- owner. service_role keeps SELECT (already bypasses RLS itself, as it
-- has to for backend tooling).
-- ---------------------------------------------------------------------------

ALTER VIEW public.session_events SET (security_invoker = true);

REVOKE ALL ON public.session_events FROM anon;
REVOKE ALL ON public.session_events FROM authenticated;
GRANT SELECT ON public.session_events TO service_role;

COMMENT ON VIEW public.session_events IS
  'SUSPENDED (P40.1): compatibility view over game_events, retained for possible future use. No client grants -- service_role only. security_invoker=true so it honours game_events RLS if ever re-enabled. Grant SELECT to authenticated to reactivate.';
