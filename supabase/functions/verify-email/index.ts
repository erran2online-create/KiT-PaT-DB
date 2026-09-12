// P43: lets an already-signed-in member verify an email address. Two
// actions on one POST endpoint: { action: "send", email } and
// { action: "confirm", code }.
//
// Reuses send-sms-otp/send-telegram-otp's exact OTP conventions (6-digit
// code, salt:sha256hash storage, 5-minute expiry, otp_verification's
// existing attempt/rate-limit shape) -- those two functions and verify-otp
// were read in full before writing this, and are not touched. This
// function writes its own purpose='email_verify' rows (see
// 20260910020000_p43_identity_change.sql's header for why otp_verification
// needed a user_id/email/purpose extension, not just a bare purpose
// column, to represent this).
//
// NEVER writes auth.users.email -- the app's identity is the phone;
// public.users.email is the app's own contact column only. The actual
// write (users.email + users.email_verified_at, in one statement) happens
// inside confirm_email_verification, a service_role-only SQL function --
// this edge function verifies the caller's JWT and does the send-side
// rate limiting, but never touches users.email_verified_at itself
// directly (blocked for any non-service_role caller anyway, by
// public.users_guard_identity_columns).
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPA_SERVICE_ROLE_KEY")

// Confirmed by reading supabase/functions/admin-reveal/index.ts, the only
// other function in this repo that sends email via Resend -- these are
// the exact secret names already in use there, not assumed here.
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

function fail(code: string, status: number) {
  return json({ error: code }, status)
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

async function sha256Hex(v: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(v))
  return Array.from(new Uint8Array(d)).map((x) => x.toString(16).padStart(2, "0")).join("")
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 200, headers: corsHeaders })
  if (req.method !== "POST") return fail("KITPAT_METHOD_NOT_ALLOWED", 405)
  if (!URL || !SERVICE) return fail("KITPAT_NOT_CONFIGURED", 503)

  try {
    const authHeader = req.headers.get("Authorization") || ""
    const token = authHeader.replace(/^Bearer\s+/i, "").trim()
    if (!token) return fail("KITPAT_UNAUTHENTICATED", 401)

    const sb = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } })

    const { data: { user }, error: userErr } = await sb.auth.getUser(token)
    if (userErr || !user) return fail("KITPAT_UNAUTHENTICATED", 401)

    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>
    const action = typeof body.action === "string" ? body.action : ""

    if (action === "send") {
      const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : ""
      if (!EMAIL_RE.test(email)) return fail("KITPAT_INVALID_INPUT", 400)

      const { data: takenRow } = await sb
        .from("users")
        .select("id")
        .eq("email", email)
        .not("email_verified_at", "is", null)
        .neq("id", user.id)
        .maybeSingle()
      if (takenRow) return fail("KITPAT_EMAIL_IN_USE", 409)

      // Same rate-limit shape as send-sms-otp/send-telegram-otp (3 per
      // 10-minute window) -- keyed on (user_id, purpose) here since this
      // flow is authenticated, rather than (phone, channel).
      const since = new Date(Date.now() - 10 * 60 * 1000).toISOString()
      const { count } = await sb
        .from("otp_verification")
        .select("id", { count: "exact", head: true })
        .eq("user_id", user.id)
        .eq("purpose", "email_verify")
        .gte("created_at", since)
      if ((count || 0) >= 3) return fail("KITPAT_RATE_LIMITED", 429)

      if (!RESEND_API_KEY || !RESEND_FROM_EMAIL) return fail("KITPAT_EMAIL_NOT_CONFIGURED", 503)

      const otp = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, "0")
      const salt = crypto.randomUUID()
      const hash = await sha256Hex(`${salt}:${otp}`)
      const expiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString()

      const emailRes = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from: RESEND_FROM_EMAIL,
          to: [email],
          subject: "Verify your email for KiT-PaT",
          text: `Your verification code is ${otp}. It expires in 5 minutes. If you did not request this, ignore this email.`,
        }),
      })
      if (!emailRes.ok) {
        console.error("verify-email: resend send failed", { status: emailRes.status, body: await emailRes.text().catch(() => "") })
        return fail("KITPAT_EMAIL_SEND_FAILED", 502)
      }

      const { error: insErr } = await sb.from("otp_verification").insert({
        purpose: "email_verify",
        user_id: user.id,
        email,
        channel: "email",
        otp_hash: `${salt}:${hash}`,
        expires_at: expiresAt,
        is_used: false,
        attempt_count: 0,
        max_attempts: 5,
      })
      if (insErr) {
        console.error("verify-email: failed to store OTP", insErr)
        return fail("KITPAT_INTERNAL_ERROR", 500)
      }

      return json({ ok: true, expires_in: 300 })
    }

    if (action === "confirm") {
      const code = typeof body.code === "string" ? body.code.trim() : ""
      if (!/^\d{6}$/.test(code)) return fail("KITPAT_INVALID_INPUT", 400)

      const { data, error } = await sb.rpc("confirm_email_verification", { p_user_id: user.id, p_code: code })
      if (error) {
        const knownCodes = [
          "KITPAT_NOT_FOUND",
          "KITPAT_CODE_EXPIRED",
          "KITPAT_TOO_MANY_ATTEMPTS",
          "KITPAT_CODE_INVALID",
          "KITPAT_EMAIL_IN_USE",
        ]
        const code2 = (error.message || "").trim()
        const status: Record<string, number> = {
          KITPAT_NOT_FOUND: 404,
          KITPAT_CODE_EXPIRED: 409,
          KITPAT_TOO_MANY_ATTEMPTS: 429,
          KITPAT_CODE_INVALID: 400,
          KITPAT_EMAIL_IN_USE: 409,
        }
        if (knownCodes.includes(code2)) return fail(code2, status[code2])
        console.error("verify-email: confirm_email_verification failed", error)
        return fail("KITPAT_INTERNAL_ERROR", 500)
      }

      const row = Array.isArray(data) ? data[0] : data
      return json({ ok: true, email: row?.email ?? null })
    }

    return fail("KITPAT_INVALID_INPUT", 400)
  } catch (e) {
    console.error("verify-email: unhandled error", e)
    return fail("KITPAT_INTERNAL_ERROR", 500)
  }
})
