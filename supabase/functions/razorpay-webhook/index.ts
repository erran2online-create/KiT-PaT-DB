import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

/**
 * razorpay-webhook — sole source of truth for activating subscriptions.
 * Verifies X-Razorpay-Signature (HMAC-SHA256 of raw body) before any write.
 * Client-side payment-success callbacks must never update subscriptions.
 */

const KEY_SECRET = Deno.env.get("RAZORPAY_KEY_SECRET")
const WEBHOOK_SECRET = Deno.env.get("RAZORPAY_WEBHOOK_SECRET") || KEY_SECRET
const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPA_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), {
    status: s,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  })

async function hmacSha256Hex(secret: string, payload: string): Promise<string> {
  const enc = new TextEncoder()
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  )
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(payload))
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("")
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let out = 0
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return out === 0
}

function expiresFor(billingCycle: string): string {
  const days = billingCycle === "yearly" ? 365 : 30
  return new Date(Date.now() + days * 86400000).toISOString()
}

serve(async (req) => {
  if (req.method === "GET") return json({ ok: true, service: "razorpay-webhook" })
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405)

  if (!WEBHOOK_SECRET) return json({ error: "Webhook not configured" }, 503)
  if (!URL || !SERVICE) return json({ error: "Backend not configured" }, 503)

  const rawBody = await req.text()
  const signature = req.headers.get("x-razorpay-signature") || ""
  if (!signature) return json({ error: "Missing signature" }, 401)

  const expected = await hmacSha256Hex(WEBHOOK_SECRET, rawBody)
  if (!timingSafeEqual(expected, signature)) {
    return json({ error: "Invalid signature" }, 401)
  }

  let event: Record<string, unknown>
  try {
    event = JSON.parse(rawBody) as Record<string, unknown>
  } catch {
    return json({ error: "Invalid JSON" }, 400)
  }

  const eventName = String(event.event || "")
  // Activate only on captured/paid money events.
  if (!["payment.captured", "order.paid"].includes(eventName)) {
    return json({ ok: true, ignored: eventName })
  }

  const payload = (event.payload || {}) as Record<string, unknown>
  const paymentEntity = ((payload.payment as Record<string, unknown> | undefined)?.entity
    || (payload.order as Record<string, unknown> | undefined)?.entity
    || {}) as Record<string, unknown>

  const orderId = String(paymentEntity.order_id || paymentEntity.id || "")
  const paymentId = String(
    (payload.payment as Record<string, unknown> | undefined)?.entity
      ? ((payload.payment as Record<string, unknown>).entity as Record<string, unknown>).id
      : paymentEntity.id || "",
  )
  const notes = (paymentEntity.notes || {}) as Record<string, unknown>

  if (!orderId) return json({ error: "Missing order id" }, 400)

  const sb = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } })

  const { data: tx, error: txErr } = await sb
    .from("transactions")
    .select("id, user_id, plan_id, status, amount")
    .eq("razorpay_order_id", orderId)
    .maybeSingle()

  if (txErr || !tx) return json({ error: "Order not found" }, 404)

  // Idempotent: already activated
  if (tx.status === "success") {
    return json({ ok: true, already_processed: true, transaction_id: tx.id })
  }

  const billingCycle = String(notes.billing_cycle || "monthly").toLowerCase() === "yearly"
    ? "yearly"
    : "monthly"
  const planId = String(notes.plan_id || tx.plan_id)
  const userId = String(notes.user_id || tx.user_id)

  // Cancel prior active subs for this user (keep history).
  await sb
    .from("subscriptions")
    .update({ status: "cancelled", cancelled_at: new Date().toISOString(), auto_renew: false })
    .eq("user_id", userId)
    .eq("status", "active")

  const subInsert: Record<string, unknown> = {
    user_id: userId,
    plan_id: planId,
    status: "active",
    billing_cycle: billingCycle,
    started_at: new Date().toISOString(),
    expires_at: expiresFor(billingCycle),
    auto_renew: true,
  }
  // Reuse unique razorpay_subscription_id column to store payment id for traceability.
  if (paymentId) subInsert.razorpay_subscription_id = paymentId

  const { data: sub, error: subErr } = await sb
    .from("subscriptions")
    .insert(subInsert)
    .select("id")
    .single()

  if (subErr || !sub) {
    return json({ error: "Subscription update failed" }, 500)
  }

  await sb.from("transactions").update({
    status: "success",
    razorpay_payment_id: paymentId || null,
    razorpay_signature: signature,
    subscription_id: sub.id,
    updated_at: new Date().toISOString(),
  }).eq("id", tx.id)

  await sb.from("users").update({
    current_plan_id: planId,
    subscription_id: sub.id,
  }).eq("id", userId)

  return json({
    ok: true,
    subscription_id: sub.id,
    transaction_id: tx.id,
    event: eventName,
  })
})
