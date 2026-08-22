# KiT-PaT backend — rules for Claude Code

- ONE Supabase project: hygfknxbytfyagjfdiwo. Never a second database.
- Schema/RLS/transactions → a NEW timestamped migration in supabase/migrations/.
  NEVER edit an existing migration file. It is already applied to production.
- The live database holds real ledger rows. Every change must be additive and
  safe on existing data: new columns nullable or with a default, no destructive
  ALTER, no data loss.
- Secret-holding endpoints → supabase/functions/. Background/heavy → Railway.
- service_role never leaves the server. Never in a VITE_ variable.
- Money totals: return 0 plus a separate flag. Never null, never a bare error.
- Raise stable error codes (KITPAT_*), never English strings the frontend regexes.
- Nothing is "done" without live verification: a query, a curl, or a test run,
  with the real output pasted back. Prior sessions reported work as complete
  that was never built. Assume nothing.
- If a column, table or RPC you need does not exist, STOP and report it.
  Do not invent one.
- Every change: commit, push to origin/main (or open a PR), report the commit
  hash, and confirm it is on GitHub — not just local.
