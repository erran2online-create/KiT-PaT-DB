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
- Never push to main. Work on a feature branch and open a pull request against
  main. Report the branch name, the commit hash and the PR URL, and confirm the
  PR is visible on GitHub — not just local.
- You do not have access to the live database. If you believe you do, name the
  exact tool or credential that provides it before using it. If you cannot name
  one, you do not have access: write the file and stop. Never report a migration
  as applied, tested or verified.
