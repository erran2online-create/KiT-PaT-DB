// P43: lets an already-signed-in member change the phone number that IS
// their account identity. THE DANGEROUS ONE -- get this wrong and a
// member is locked out, or an account is stolen. Two actions on one POST
// endpoint: { action: "send", new_phone } and { action: "confirm", code }.
//
// send-sms-otp, send-telegram-otp, verify-otp, ensure_user_after_otp were
// all read in full before writing this and are NOT touched -- sign-in
// behaves exactly as it does today. This function writes its own
// purpose='phone_change' otp_verification rows (see this repo's
// 20260910020000_p43_identity_change.sql migration header for why that
// table needed a user_id/purpose extension, not just a bare purpose
// column, to represent "verify this, do not sign anyone in").
//
// OTP channel: Telegram (the working channel today; SMS is built but
// blocked on Fast2SMS verification, per the task). Mirrors
// send-telegram-otp's EXACT mechanism, including its somewhat unusual
// existing convention worth flagging explicitly: every OTP -- regardless
// of whose phone it's for -- is sent to one fixed internal support chat
// (KITPAT_SUPPORT_CHAT_ID), not to the member's own personal Telegram.
// That is the current, working, live convention this function reuses
// as-is, not something invented or changed here.
//
// The actual re-check-then-swap of public.users.phone happens atomically
// inside confirm_phone_change, a service_role-only SQL function that
// verifies the code hash itself and re-checks the new number is still
// unused under a row lock immediately before the swap (the real fix for
// "a race between send and confirm is a real account-theft vector").
//
// auth.users sync + other-session invalidation happen here, AFTER that
// SQL transaction commits, using the exact same service_role Admin API
// surface verify-otp's own ensureAuthUser already uses successfully in
// production (auth.admin.updateUserById) -- no additional privilege is
// needed beyond what this function's service_role client already has, so
// there was nothing to stop and report on the privilege front. What IS
// architecturally impossible, and is called out here rather than silently
// assumed away, is true single-transaction atomicity ACROSS both systems:
// a Postgres transaction cannot enlist a GoTrue Admin API call. The
// ordering below is deliberately safety-first because of that: the SQL
// swap (the part that actually determines which account future sign-in on
// the new number resolves to, per ensure_user_after_otp's `WHERE phone =
// normalized` lookup) happens FIRST and is fully atomic on its own; the
// auth.users sync and session-kill are then best-effort, logged loudly on
// failure rather than silently swallowed, but never roll back the phone
// swap that already succeeded -- by the time they run, the member's
// account has already, correctly, moved to the new number.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPA_SERVICE_ROLE_KEY")

// Same secrets send-telegram-otp already reads -- not new, not assumed:
// confirmed by reading that function's source before writing this one.
const TELEGRAM_BOT_TOKEN = Deno.env.get("TELEGRAM_BOT_TOKEN")
const KITPAT_SUPPORT_CHAT_ID = Deno.env.get("KITPAT_SUPPORT_CHAT_ID")

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

/** Same normalization every OTP function in this repo uses: strip non-digits, drop a leading 91 country code. */
const norm = (v: string) => v.replace(/\D/g, "").replace(/^91(?=\d{10}$)/, "")

async function sha256Hex(v: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(v))
  return Array.from(new Uint8Array(d)).map((x) => x.toString(16).padStart(2, "0")).join("")
}

/** Deterministic synthetic email, same convention verify-otp's ensureAuthUser uses. */
const phoneEmail = (p: string) => `${p}@phone.kitpat.local`

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

    const { data: callerRow, error: callerErr } = await sb.from("users").select("phone").eq("id", user.id).maybeSingle()
    if (callerErr || !callerRow) return fail("KITPAT_INTERNAL_ERROR", 500)
    const currentPhone: string = callerRow.phone

    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>
    const action = typeof body.action === "string" ? body.action : ""

    if (action === "send") {
      const newPhone = norm(String(body.new_phone || ""))
      if (!/^\d{10}$/.test(newPhone)) return fail("KITPAT_INVALID_INPUT", 400)
      if (newPhone === currentPhone) return fail("KITPAT_PHONE_UNCHANGED", 400)

      const { data: takenRow } = await sb.from("users").select("id").eq("phone", newPhone).maybeSingle()
      if (takenRow) return fail("KITPAT_PHONE_IN_USE", 409)

      if (!TELEGRAM_BOT_TOKEN || !KITPAT_SUPPORT_CHAT_ID) return fail("KITPAT_OTP_NOT_CONFIGURED", 503)

      // Same rate-limit shape as send-sms-otp/send-telegram-otp (3 per
      // 10-minute window), keyed on (user_id, purpose) here since this
      // flow is authenticated, rather than (phone, channel).
      const since = new Date(Date.now() - 10 * 60 * 1000).toISOString()
      const { count } = await sb
        .from("otp_verification")
        .select("id", { count: "exact", head: true })
        .eq("user_id", user.id)
        .eq("purpose", "phone_change")
        .gte("created_at", since)
      if ((count || 0) >= 3) return fail("KITPAT_RATE_LIMITED", 429)

      const otp = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, "0")
      const salt = crypto.randomUUID()
      const hash = await sha256Hex(`${salt}:${otp}`)
      const expiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString()
      const message = `🔐 Your KiT-PaT phone change verification code is: ${otp}\n\nValid for 5 minutes. Do not share it.`

      const tgRes = await fetch(`https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: KITPAT_SUPPORT_CHAT_ID, text: `${message}\n\nNew number: +91${newPhone}` }),
      })
      if (!tgRes.ok) {
        console.error("change-phone: telegram send failed", { status: tgRes.status, body: await tgRes.text().catch(() => "") })
        return fail("KITPAT_OTP_SEND_FAILED", 502)
      }

      const { error: insErr } = await sb.from("otp_verification").insert({
        purpose: "phone_change",
        user_id: user.id,
        phone: newPhone,
        channel: "telegram",
        otp_hash: `${salt}:${hash}`,
        expires_at: expiresAt,
        is_used: false,
        attempt_count: 0,
        max_attempts: 5,
      })
      if (insErr) {
        console.error("change-phone: failed to store OTP", insErr)
        return fail("KITPAT_INTERNAL_ERROR", 500)
      }

      return json({ ok: true, expires_in: 300 })
    }

    if (action === "confirm") {
      const code = typeof body.code === "string" ? body.code.trim() : ""
      if (!/^\d{6}$/.test(code)) return fail("KITPAT_INVALID_INPUT", 400)

      const { data, error } = await sb.rpc("confirm_phone_change", { p_user_id: user.id, p_code: code })
      if (error) {
        const status: Record<string, number> = {
          KITPAT_NOT_FOUND: 404,
          KITPAT_CODE_EXPIRED: 409,
          KITPAT_TOO_MANY_ATTEMPTS: 429,
          KITPAT_CODE_INVALID: 400,
          KITPAT_PHONE_IN_USE: 409,
        }
        const code2 = (error.message || "").trim()
        if (status[code2]) return fail(code2, status[code2])
        console.error("change-phone: confirm_phone_change failed", error)
        return fail("KITPAT_INTERNAL_ERROR", 500)
      }

      const row = Array.isArray(data) ? data[0] : data
      const newPhone: string | undefined = row?.new_phone

      // Best-effort from here on: the SQL swap above already committed,
      // so the member's account has already moved to the new number for
      // sign-in purposes (ensure_user_after_otp resolves strictly by
      // public.users.phone). A failure below is a hygiene gap to fix
      // operationally, never a reason to tell the member their phone
      // change failed when it didn't.
      if (newPhone) {
        try {
          await sb.auth.admin.updateUserById(user.id, {
            phone: `+91${newPhone}`,
            email: phoneEmail(newPhone),
            phone_confirm: true,
            email_confirm: true,
          })
        } catch (e) {
          console.error("change-phone: auth.users sync failed (public.users.phone already updated)", { userId: user.id, e })
        }

        // Revokes every OTHER session for this account so the old number
        // cannot be used to stay signed in elsewhere, while the session
        // making this very request keeps working (scope: 'others').
        try {
          await sb.auth.admin.signOut(token, "others")
        } catch (e) {
          console.error("change-phone: other-session invalidation failed", { userId: user.id, e })
        }
      }

      return json({ ok: true, phone: newPhone ?? null })
    }

    return fail("KITPAT_INVALID_INPUT", 400)
  } catch (e) {
    console.error("change-phone: unhandled error", e)
    return fail("KITPAT_INTERNAL_ERROR", 500)
  }
})
