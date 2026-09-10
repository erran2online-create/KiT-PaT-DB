// P41: a member describes a food/beverage in text; this function asks an
// AI provider for approximate macros and returns them to the client. It
// does NOT save anything itself -- the client calls record_food_entry()
// separately with the values this function returns (letting the member
// review/adjust serving and choose whether to share to a group before it
// is persisted). NOT a health/medical feature, NOT a vision feature: text
// description in, approximate estimate out.
//
// Two Postgres clients, same split as admin-write/admin-reveal:
//   - `sbService` (service_role) resolves the caller's identity from
//     their JWT (auth.getUser) and does the plan-limit usage count
//     (bypassing RLS is fine here -- it is only ever counting the
//     caller's own rows).
//   - `sbUser` forwards the caller's own Authorization header, so
//     get_user_plan_limits(p_user_id) -- which requires auth.uid() to
//     equal p_user_id for a non-admin caller -- resolves correctly.
//
// Plan limit: plans.limits carries 'ai_calls_per_month' (verified against
// the live plans rows: Free 10, Starter 50, Queen 500, Empress -1).
// -1 means unlimited, the same convention used by every other key in
// limits (max_parties_per_month, max_groups, ...) -- never enforced.
// Usage is counted directly from food_entries (no separate counter
// table): rows for this user, this UTC calendar month, with
// ai_provider IS NOT NULL -- an AI call is what created the entry. If the
// limits lookup is missing the key or fails outright, this function FAILS
// OPEN (proceeds, logs server-side) -- a broken limits lookup must never
// block a paying member from using a feature they're entitled to.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPA_SERVICE_ROLE_KEY")
const ANON = Deno.env.get("SUPABASE_ANON_KEY")

// Provider selection: ANTHROPIC_API_KEY is preferred when both are set.
// Neither being set is a real, expected configuration state until an
// operator sets one -- see this PR's description for the exact secret
// names required.
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY")
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")
const ANTHROPIC_MODEL = Deno.env.get("ANTHROPIC_MODEL") || "claude-haiku-4-5-20251001"
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") || "gpt-4o-mini"

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

/** Never put raw exception text / provider error detail in a client-facing body. */
function fail(code: string, status: number) {
  return json({ error: code }, status)
}

type Macros = {
  calories_kcal: number | null
  protein_g: number | null
  fat_g: number | null
  carbs_g: number | null
  serving: string | null
  confidence: number | null
}

function buildPrompt(description: string, serving: string | null): string {
  return [
    "You are a nutrition estimator. Given a short text description of a food or beverage (and an optional serving size), estimate its approximate macros.",
    "Respond with ONLY a single JSON object, no markdown fences, no commentary, no explanation -- just the JSON. The object MUST have exactly these keys:",
    '{"calories_kcal": number, "protein_g": number, "fat_g": number, "carbs_g": number, "serving": string, "confidence": number}',
    "calories_kcal/protein_g/fat_g/carbs_g are your best approximate numeric estimate for the described serving (use null for any you genuinely cannot estimate). serving is your best guess at the serving size as a short string (echo the given one if provided). confidence is a number from 0 to 1.",
    `Description: ${description}`,
    serving ? `Stated serving: ${serving}` : "No serving size was stated -- assume a typical single serving.",
  ].join("\n")
}

/** Strips a markdown code fence if the model added one anyway, then parses. Never throws -- returns null on any failure. */
function parseMacros(raw: string): Macros | null {
  try {
    const cleaned = raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/, "")
    const data = JSON.parse(cleaned)
    if (typeof data !== "object" || data === null || Array.isArray(data)) return null

    const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null)
    const str = (v: unknown): string | null => (typeof v === "string" && v.trim() !== "" ? v : null)

    return {
      calories_kcal: num(data.calories_kcal),
      protein_g: num(data.protein_g),
      fat_g: num(data.fat_g),
      carbs_g: num(data.carbs_g),
      serving: str(data.serving),
      confidence: num(data.confidence),
    }
  } catch {
    return null
  }
}

async function callAnthropic(prompt: string): Promise<string | null> {
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": ANTHROPIC_API_KEY as string,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: ANTHROPIC_MODEL,
      max_tokens: 300,
      messages: [{ role: "user", content: prompt }],
    }),
  })
  if (!res.ok) {
    console.error("analyze-food: anthropic call failed", { status: res.status, body: await res.text().catch(() => "") })
    return null
  }
  const data = await res.json().catch(() => null)
  const text = data?.content?.[0]?.text
  return typeof text === "string" ? text : null
}

async function callOpenAI(prompt: string): Promise<string | null> {
  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      messages: [{ role: "user", content: prompt }],
      response_format: { type: "json_object" },
      max_tokens: 300,
    }),
  })
  if (!res.ok) {
    console.error("analyze-food: openai call failed", { status: res.status, body: await res.text().catch(() => "") })
    return null
  }
  const data = await res.json().catch(() => null)
  const text = data?.choices?.[0]?.message?.content
  return typeof text === "string" ? text : null
}

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
    if (userErr || !user) return fail("KITPAT_UNAUTHENTICATED", 401)

    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>
    const description = typeof body.description === "string" ? body.description.trim() : ""
    const serving = typeof body.serving === "string" && body.serving.trim() !== "" ? body.serving.trim() : null

    if (!description) return fail("KITPAT_DESCRIPTION_REQUIRED", 400)

    // Forwards the caller's own Authorization header so auth.uid() inside
    // get_user_plan_limits resolves to this same user (it requires
    // auth.uid() = p_user_id for a non-admin caller).
    const sbUser = createClient(URL, ANON, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    })

    let allowed = true
    const { data: limits, error: limitsErr } = await sbUser.rpc("get_user_plan_limits", { p_user_id: user.id })
    if (limitsErr) {
      console.error("analyze-food: get_user_plan_limits failed, failing open", { userId: user.id, limitsErr })
    } else {
      const rawLimit = limits && typeof limits === "object" ? (limits as Record<string, unknown>).ai_calls_per_month : undefined
      const limit = typeof rawLimit === "number" ? rawLimit : null
      if (limit === null) {
        console.error("analyze-food: plans.limits has no ai_calls_per_month key, failing open", { userId: user.id, limits })
      } else if (limit !== -1) {
        const startOfMonth = new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), 1)).toISOString()
        const { count, error: countErr } = await sbService
          .from("food_entries")
          .select("id", { count: "exact", head: true })
          .eq("user_id", user.id)
          .not("ai_provider", "is", null)
          .gte("created_at", startOfMonth)
        if (countErr) {
          console.error("analyze-food: usage count failed, failing open", { userId: user.id, countErr })
        } else if ((count ?? 0) >= limit) {
          allowed = false
        }
      }
    }
    if (!allowed) return fail("KITPAT_PLAN_LIMIT_REACHED", 403)

    const provider: "anthropic" | "openai" | null = ANTHROPIC_API_KEY ? "anthropic" : OPENAI_API_KEY ? "openai" : null
    if (!provider) return fail("KITPAT_AI_NOT_CONFIGURED", 503)

    const prompt = buildPrompt(description, serving)
    const raw = provider === "anthropic" ? await callAnthropic(prompt) : await callOpenAI(prompt)
    if (raw === null) return fail("KITPAT_AI_UNAVAILABLE", 502)

    const macros = parseMacros(raw)
    if (macros === null) {
      console.error("analyze-food: unparseable model output", { provider, raw })
      return fail("KITPAT_AI_UNAVAILABLE", 502)
    }

    return json({
      ok: true,
      calories_kcal: macros.calories_kcal,
      protein_g: macros.protein_g,
      fat_g: macros.fat_g,
      carbs_g: macros.carbs_g,
      serving: macros.serving ?? serving,
      confidence: macros.confidence,
      ai_provider: provider,
      ai_model: provider === "anthropic" ? ANTHROPIC_MODEL : OPENAI_MODEL,
    })
  } catch (e) {
    console.error("analyze-food: unhandled error", e)
    return fail("KITPAT_INTERNAL_ERROR", 500)
  }
})
