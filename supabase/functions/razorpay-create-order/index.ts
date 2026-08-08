import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

/**
 * razorpay-create-order — server-side Razorpay order for app subscription plans.
 * Amount is derived from public.plans (never trust client amount).
 * Does NOT activate subscriptions — razorpay-webhook is the sole source of truth.
 */

const KEY_ID = Deno.env.get("RAZORPAY_KEY_ID")
const KEY_SECRET = Deno.env.get("RAZORPAY_KEY_SECRET")
const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPA_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

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

function safeError(message: string, status: number) {
  return json({ error: message }, status)
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 200, headers: corsHeaders })
  if (req.method !== "POST") return safeError("Method Not Allowed", 405)

  if (!KEY_ID || !KEY_SECRET) return safeError("Payment service not configured", 503)
  if (!URL || !SERVICE) return safeError("Backend not configured", 503)

  try {
    const auth = req.headers.get("Authorization")
    if (!auth) return safeError("Unauthorized", 401)

    const sb = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } })
    const token = auth.replace(/^Bearer\s+/i, "")
    const { data: { user }, error: userErr } = await sb.auth.getUser(token)
    if (userErr || !user) return safeError("Unauthorized", 401)

    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    // Kitty pool payments are out of scope — subscription plans only.
    if (body.pool_id || body.poolId) {
      return safeError("Kitty contributions are not paid via Razorpay; use plan_id for subscriptions", 400)
    }

    const plan_id = String(body.plan_id || body.planId || "")
    const billing_cycle = String(body.billing_cycle || body.billingCycle || "monthly").toLowerCase()
    if (!plan_id) return safeError("plan_id required", 400)
    if (!["monthly", "yearly"].includes(billing_cycle)) {
      return safeError("billing_cycle must be monthly or yearly", 400)
    }

    const { data: plan, error: planErr } = await sb
      .from("plans")
      .select("id, slug, name, price_monthly, price_yearly, currency, is_active")
      .eq("id", plan_id)
      .maybeSingle()

    if (planErr || !plan || plan.is_active !== true) return safeError("Invalid plan", 400)

    const amountRupees = Number(billing_cycle === "yearly" ? plan.price_yearly : plan.price_monthly)
    if (!Number.isFinite(amountRupees) || amountRupees <= 0) {
      return safeError("Plan does not require payment", 400)
    }

    // Optional client amount — may only match server price (rupees).
    if (body.amount !== undefined && body.amount !== null && body.amount !== "") {
      const claimed = Number(body.amount)
      if (claimed !== amountRupees) return safeError("Amount mismatch", 400)
    }

    const amountPaise = Math.round(amountRupees * 100)
    const credentials = btoa(`${KEY_ID}:${KEY_SECRET}`)
    const receipt = `kitpat_${user.id.replace(/-/g, "").slice(0, 12)}_${Date.now()}`.slice(0, 40)

    const rzpRes = await fetch("https://api.razorpay.com/v1/orders", {
      method: "POST",
      headers: {
        Authorization: `Basic ${credentials}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        amount: amountPaise,
        currency: plan.currency || "INR",
        receipt,
        notes: {
          plan_id,
          plan_slug: plan.slug,
          billing_cycle,
          user_id: user.id,
        },
      }),
    })

    const rzpBody = await rzpRes.json().catch(() => ({})) as Record<string, unknown>
    if (!rzpRes.ok) {
      const err = rzpBody.error as { description?: string; code?: string } | undefined
      return json({
        error: "Payment provider error",
        detail: err?.description || err?.code || `HTTP ${rzpRes.status}`,
      }, 502)
    }
    const order = rzpBody as { id?: string }
    if (!order.id) return safeError("Payment provider error", 502)

    const { error: txErr } = await sb.from("transactions").insert({
      user_id: user.id,
      plan_id,
      amount: amountRupees,
      currency: plan.currency || "INR",
      status: "pending",
      razorpay_order_id: order.id,
      payment_method: "razorpay",
    })
    if (txErr) return safeError("Failed to record order", 500)

    // key_id is public (Checkout.js); key_secret never returned.
    return json({
      order_id: order.id,
      amount: amountPaise,
      currency: plan.currency || "INR",
      key_id: KEY_ID,
      plan_id,
      billing_cycle,
    })
  } catch {
    return safeError("Failed to create order", 500)
  }
})
