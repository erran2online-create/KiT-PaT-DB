// P30: daily sweep for due account_deletion_requests.
//
// Invoked by pg_cron via public.trigger_process_account_deletions(), which
// POSTs here with the project's service_role key as the Authorization
// bearer token (same vault-secret pattern as public.tambola_broadcast()).
// Supabase's platform-level JWT verification only proves "this is a validly
// signed project JWT" — it does NOT prove the caller is service_role, since
// any authenticated user's own JWT would also pass that gate. This function
// therefore checks the bearer token against the service_role key itself
// (a shared secret only the server ever holds) before doing anything.
//
// Per request: finalize_account_deletion() (SQL, service_role-only) does
// the anonymise + members-row cleanup atomically. auth.admin.deleteUser()
// then removes the auth.users row — a GoTrue Admin API call that cannot
// participate in that same DB transaction, which is why it happens after
// and why the request is only marked 'done' once that succeeds. A retried
// run (e.g. after a crash mid-loop) is safe: re-finalizing an
// already-anonymised user is a no-op, and a "user not found" from
// deleteUser on a retry is treated as already-done rather than an error.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPA_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), {
    status: s,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  })

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405)

  const authHeader = req.headers.get("Authorization") || ""
  const token = authHeader.replace(/^Bearer\s+/i, "").trim()
  if (!SERVICE || !URL || token !== SERVICE) {
    return json({ error: "KITPAT_UNAUTHORIZED" }, 401)
  }

  const sb = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } })

  const { data: due, error: dueErr } = await sb
    .from("account_deletion_requests")
    .select("id, user_id")
    .eq("status", "pending")
    .lte("scheduled_for", new Date().toISOString())

  if (dueErr) return json({ error: "KITPAT_QUERY_FAILED", detail: dueErr.message }, 500)

  const results: Array<{ request_id: string; user_id: string; ok: boolean; error?: string }> = []

  for (const row of due ?? []) {
    try {
      const { error: finalizeErr } = await sb.rpc("finalize_account_deletion", { p_request_id: row.id })
      if (finalizeErr) throw new Error(finalizeErr.message)

      const { error: deleteErr } = await sb.auth.admin.deleteUser(row.user_id)
      // A retry after a previous partial run may find the auth user already
      // gone — that is success, not a failure to report.
      if (deleteErr && !/not\s*found/i.test(deleteErr.message || "")) {
        throw new Error(deleteErr.message)
      }

      const { error: doneErr } = await sb
        .from("account_deletion_requests")
        .update({ status: "done", completed_at: new Date().toISOString() })
        .eq("id", row.id)
      if (doneErr) throw new Error(doneErr.message)

      results.push({ request_id: row.id, user_id: row.user_id, ok: true })
    } catch (e) {
      results.push({
        request_id: row.id,
        user_id: row.user_id,
        ok: false,
        error: e instanceof Error ? e.message : String(e),
      })
    }
  }

  return json({ ok: true, processed: results.length, results })
})
