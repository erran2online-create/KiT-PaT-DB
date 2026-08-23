// P30: public, unauthenticated account-deletion info page.
//
// Google Play's Data Safety policy requires a stable, web-reachable URL
// explaining what account deletion does and how to request it, even though
// the actual deletion must be requested from inside the authenticated app
// (request_account_deletion() needs a real session — a public page can't
// safely trigger it for an arbitrary visitor). This function only explains
// the process; it never touches the database.
//
// Must be deployed with verify_jwt = false (see supabase/config.toml) so it
// is reachable with no Authorization header at all, matching the "public
// unauthenticated GET page" requirement.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Delete your KiT-PaT account</title>
<style>
  :root { color-scheme: light; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 640px; margin: 0 auto; padding: 2.5rem 1.5rem 4rem; color: #1a1a2e; line-height: 1.6; }
  h1 { font-size: 1.5rem; margin-bottom: 0.25rem; }
  h2 { font-size: 1.1rem; margin-top: 2rem; }
  .muted { color: #666; font-size: 0.95rem; }
  ul { padding-left: 1.25rem; }
  .box { background: #f6f6fb; border: 1px solid #e2e2ef; border-radius: 10px; padding: 1rem 1.25rem; margin: 1.25rem 0; }
  code { background: #eee; padding: 0.1rem 0.35rem; border-radius: 4px; font-size: 0.9em; }
  a { color: #5b3fd6; }
</style>
</head>
<body>
  <h1>Delete your KiT-PaT account</h1>
  <p class="muted">This page explains what happens when you delete your KiT-PaT account and how to request it.</p>

  <h2>How to request deletion</h2>
  <ol>
    <li>Open the KiT-PaT app and sign in.</li>
    <li>Go to <strong>Settings → Account → Delete Account</strong>.</li>
    <li>Confirm. Your request is recorded immediately with a 7-day grace period before anything changes.</li>
  </ol>
  <p>You can cancel the request from the same screen at any point during those 7 days.</p>

  <h2>What happens after the 7-day grace period</h2>
  <div class="box">
    <ul>
      <li>Your profile is anonymised: your name is replaced with "Deleted member", and your phone number, Telegram ID, avatar, and city are permanently removed.</li>
      <li>You are removed from every group you were a member of.</li>
      <li>Your login is permanently deleted — you will no longer be able to sign in.</li>
    </ul>
  </div>

  <h2>What is kept, and why</h2>
  <p>
    Contributions and expenses you were part of stay in each group's ledger so that
    other members' balances and group totals remain accurate — a shared kitty's
    history shouldn't become wrong because one member left. These ledger entries
    are no longer linked to any identifying information about you once your
    profile has been anonymised.
  </p>

  <h2>If you host a group</h2>
  <p>
    If you are the only host of a group that still has other members, you'll need
    to transfer hosting to someone else in that group before your deletion request
    can be accepted — a group's history shouldn't disappear because its host left.
  </p>

  <h2>Questions</h2>
  <p>Contact <a href="mailto:support@kitpat.app">support@kitpat.app</a> for help with account deletion or data requests.</p>
</body>
</html>`

serve((req) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("Method Not Allowed", { status: 405 })
  }
  return new Response(req.method === "HEAD" ? null : html, {
    status: 200,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "public, max-age=3600",
    },
  })
})
