// AP2: owner-only, double-verified reveal of a user's real phone/email.
//
// Two steps, two independent factors, both required before any raw value
// ever leaves this function:
//   'request' -- caller must be an ACTIVE owner (re-derived from their JWT,
//                never trusted from the client). Calls admin_request_reveal,
//                which returns a 6-digit code. That code is emailed to the
//                admin's OWN address via Resend and is NEVER included in
//                this function's response to the browser.
//   'confirm' -- caller must re-enter their account PASSWORD (verified via
//                signInWithPassword against their own account) AND the
//                6-digit code (verified by admin_confirm_reveal). Only then
//                is the one revealed field returned.
//
// Two Postgres clients, same split as admin-write:
//   - `sbService` (service_role) resolves the caller's identity from their
//     JWT (auth.getUser) and looks up their admins row -- the edge-function
//     -level role gate.
//   - `sbUser` forwards the caller's own Authorization header, so
//     auth.jwt()/is_admin_owner() resolve correctly *inside*
//     admin_request_reveal/admin_confirm_reveal -- those RPCs are the
//     single source of truth for "may this admin reveal this field",
//     re-checked independently of the gate above.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPA_SERVICE_ROLE_KEY")
const ANON = Deno.env.get("SUPABASE_ANON_KEY")
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")
const RESEND_FROM_EMAIL = Deno.env.get("RESEND_FROM_EMAIL")

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), {
    status: s,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...corsHeaders },
  })

/** Never put raw exception text / Postgres error detail in a client-facing body. */
function fail(code: string, status: number) {
  return json({ error: code }, status)
}

// Exception messages admin_request_reveal / admin_confirm_reveal are known
// to raise (see 20260907030000_ap2_admin_reveal_with_verification.sql).
// Anything else from Postgres is collapsed to KITPAT_INTERNAL_ERROR so raw
// exception text never reaches the client.
const RPC_ERROR_STATUS: Record<string, number> = {
  KITPAT_INSUFFICIENT_ROLE: 403,
  KITPAT_ADMIN_ONLY: 403,
  KITPAT_INVALID_FIELD: 400,
  KITPAT_NOT_FOUND: 404,
  KITPAT_NO_EMAIL_ON_FILE: 404,
  KITPAT_REVEAL_CODE_EXPIRED: 400,
  KITPAT_REVEAL_LOCKED: 423,
  KITPAT_REVEAL_CODE_INVALID: 400,
}

function rpcFailure(message: string | undefined) {
  const code = (message || "").trim()
  const status = RPC_ERROR_STATUS[code]
  return status ? fail(code, status) : fail("KITPAT_INTERNAL_ERROR", 500)
}

type RequestStep = { step: "request"; user_id: string; field: "phone" | "email" }
type ConfirmStep = { step: "confirm"; request_id: string; code: string; password: string }

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 200, headers: corsHeaders })
  if (req.method !== "POST") return fail("KITPAT_METHOD_NOT_ALLOWED", 405)
  if (!URL || !SERVICE || !ANON) return fail("KITPAT_NOT_CONFIGURED", 503)

  try {
    const authHeader = req.headers.get("Authorization") || ""
    const token = authHeader.replace(/^Bearer\s+/i, "").trim()
    if (!token) return fail("KITPAT_UNAUTHENTICATED", 401)

    const sbService = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } })

    const { data: { user }, error: userErr } = await sbService.auth.getUser(token)
    if (userErr || !user || !user.email) return fail("KITPAT_UNAUTHENTICATED", 401)

    // Resolve the caller's admin record ourselves (service client, bypasses
    // RLS) rather than trusting anything the client sent. Owner-only, and
    // must be active -- both the edge-function gate here and
    // is_admin_owner() inside the RPCs below independently enforce this.
    const { data: adminRow, error: adminErr } = await sbService
      .from("admins")
      .select("id, role, is_active")
      .eq("email", user.email)
      .maybeSingle()
    if (adminErr || !adminRow || !adminRow.is_active || adminRow.role !== "owner") {
      return fail("KITPAT_INSUFFICIENT_ROLE", 403)
    }

    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>
    const step = String(body.step || "")

    // Forwards the caller's own Authorization header so auth.jwt() resolves
    // correctly inside the SECURITY DEFINER RPCs (mirrors admin-write's
    // sbUser / admin_can_write split).
    const sbUser = createClient(URL, ANON, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    })

    if (step === "request") {
      const userId = body.user_id != null ? String(body.user_id) : ""
      const field = String(body.field || "")
      if (!userId || (field !== "phone" && field !== "email")) return fail("KITPAT_PAYLOAD_REQUIRED", 400)

      // Fail fast, before minting a reveal request, if there's nowhere to
      // send the code -- never fall back to logging it or returning it.
      if (!RESEND_API_KEY || !RESEND_FROM_EMAIL) return fail("KITPAT_EMAIL_NOT_CONFIGURED", 503)

      const { data, error } = await sbUser.rpc("admin_request_reveal", {
        p_user_id: userId,
        p_field: field,
      } satisfies { p_user_id: string; p_field: string })
      if (error || !data) return rpcFailure(error?.message)

      const { request_id, expires_in, code } = data as { request_id: string; expires_in: number; code: string }

      const emailRes = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${RESEND_API_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          from: RESEND_FROM_EMAIL,
          to: [user.email],
          subject: "KiT-PaT admin reveal code",
          text: `Your one-time reveal code is ${code}. It expires in ${Math.floor(expires_in / 60)} minutes. If you did not request this, ignore this email.`,
        }),
      })
      if (!emailRes.ok) {
        console.error("admin-reveal: resend send failed", { status: emailRes.status, body: await emailRes.text().catch(() => "") })
        return fail("KITPAT_EMAIL_SEND_FAILED", 502)
      }

      // The plaintext code stops here -- never forwarded to the browser.
      return json({ ok: true, request_id, expires_in })
    }

    if (step === "confirm") {
      const requestId = body.request_id != null ? String(body.request_id) : ""
      const code = body.code != null ? String(body.code) : ""
      const password = body.password != null ? String(body.password) : ""
      if (!requestId || !code || !password) return fail("KITPAT_PAYLOAD_REQUIRED", 400)

      // Second factor: the admin's own account password, re-verified fresh
      // (not just "has a valid session") against their own email.
      const sbAuth = createClient(URL, ANON, { auth: { persistSession: false, autoRefreshToken: false } })
      const { error: signInErr } = await sbAuth.auth.signInWithPassword({ email: user.email, password })
      if (signInErr) return fail("KITPAT_REVEAL_AUTH_FAILED", 401)

      const { data, error } = await sbUser.rpc("admin_confirm_reveal", {
        p_request_id: requestId,
        p_code: code,
      } satisfies { p_request_id: string; p_code: string })
      if (error || !data) return rpcFailure(error?.message)

      const { field, value } = data as { field: string; value: string }
      return json({ ok: true, field, value })
    }

    return fail("KITPAT_INVALID_STEP", 400)
  } catch (e) {
    console.error("admin-reveal: unhandled error", e)
    return fail("KITPAT_INTERNAL_ERROR", 500)
  }
})
