// P46: called ONLY when find_recipe (the shared library, see this repo's
// 20260914020000_p46_recipes.sql) misses -- a plain macro lookup never
// pays for a recipe nobody opened. Same two-client split as analyze-food,
// read in full before writing this and mirrored deliberately:
//   - `sbService` (service_role) resolves the caller's identity, counts
//     usage, and writes recipes.
//   - `sbUser` forwards the caller's own Authorization header so
//     get_user_plan_limits(p_user_id) resolves correctly (it requires
//     auth.uid() = p_user_id for a non-admin caller).
//
// Plan limit: exactly analyze-food's mechanism (same ai_calls_per_month
// key from plans.limits, same fail-open-on-a-broken-lookup behaviour, same
// -1-is-unlimited convention), with feature='recipe_lookup' in place of
// 'food_analysis'. This is a literal, direct mirror -- recipe_lookup gets
// its own independent monthly counter under the same numeric cap, not a
// budget shared with food_analysis, exactly as analyze-food's own count
// query is scoped to one feature string. input_kind is always 'text' (no
// image path exists for a recipe lookup).
//
// The provider is asked for JSON only: {title, cuisine, serves,
// prep_minutes, cook_minutes, ingredients:[{item,quantity}], steps:[...],
// notes}. On success this inserts into public.recipes with source='ai',
// keyed on normalize_food_key(title) (see that migration's header for why
// the key is derived from the AI's own canonical title, not the member's
// raw search text) -- ON CONFLICT (normalized_key) DO NOTHING, then a
// re-SELECT on conflict, so two concurrent misses for the same dish can
// never violate the UNIQUE constraint or return an error to either caller:
// whoever loses the race still gets the recipe the winner just inserted.
//
// Unparseable model output -> KITPAT_AI_UNAVAILABLE, inserts nothing (per
// the task exactly) -- unlike analyze-food, there is no "cache the
// approximate result anyway" fallback here: a recipe with an invalid or
// missing title is not worth keeping in a shared library at all.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPA_SERVICE_ROLE_KEY")
const ANON = Deno.env.get("SUPABASE_ANON_KEY")

// Same provider secrets analyze-food already reads -- not new, not
// assumed: confirmed by reading that function's source before writing
// this one. Anthropic is preferred when both are configured.
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

type ParsedRecipe = {
  title: string
  cuisine: string | null
  serves: number | null
  prep_minutes: number | null
  cook_minutes: number | null
  ingredients: { item: string; quantity: string }[]
  steps: string[]
  notes: string | null
}

function buildPrompt(description: string): string {
  return [
    "You are a home-cooking recipe writer. Given a short description of a dish, produce a complete, practical recipe for it.",
    "Respond with ONLY a single JSON object, no markdown fences, no commentary, no explanation -- just the JSON. The object MUST have exactly these keys:",
    '{"title": string, "cuisine": string, "serves": number, "prep_minutes": number, "cook_minutes": number, "ingredients": [{"item": string, "quantity": string}], "steps": [string], "notes": string}',
    "title is the clean, canonical name of the dish (not an echo of the description below). cuisine is a short cuisine label. serves/prep_minutes/cook_minutes are your best practical integer estimates. ingredients is an ordered list of {item, quantity}. steps is an ordered list of clear instructions. notes is one short practical tip, or an empty string if none.",
    `Dish: ${description}`,
  ].join("\n")
}

/** Strips a markdown code fence if the model added one anyway, then parses. Never throws -- returns null on any failure, including a missing/blank title. */
function parseRecipe(raw: string): ParsedRecipe | null {
  try {
    const cleaned = raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/, "")
    const data = JSON.parse(cleaned)
    if (typeof data !== "object" || data === null || Array.isArray(data)) return null

    const title = typeof data.title === "string" ? data.title.trim() : ""
    if (!title) return null

    const str = (v: unknown): string | null => (typeof v === "string" && v.trim() !== "" ? v.trim() : null)
    const int = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? Math.round(v) : null)

    const ingredients = Array.isArray(data.ingredients)
      ? data.ingredients
          .filter((x: unknown): x is Record<string, unknown> => typeof x === "object" && x !== null && !Array.isArray(x))
          .map((x: Record<string, unknown>) => ({
            item: typeof x.item === "string" ? x.item.trim() : "",
            quantity: typeof x.quantity === "string" ? x.quantity.trim() : "",
          }))
          .filter((x: { item: string }) => x.item !== "")
      : []

    const steps = Array.isArray(data.steps)
      ? data.steps.filter((s: unknown): s is string => typeof s === "string" && s.trim() !== "").map((s: string) => s.trim())
      : []

    return {
      title,
      cuisine: str(data.cuisine),
      serves: int(data.serves),
      prep_minutes: int(data.prep_minutes),
      cook_minutes: int(data.cook_minutes),
      ingredients,
      steps,
      notes: str(data.notes),
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
      max_tokens: 1024,
      messages: [{ role: "user", content: prompt }],
    }),
  })
  if (!res.ok) {
    console.error("get-recipe: anthropic call failed", { status: res.status, body: await res.text().catch(() => "") })
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
      max_tokens: 1024,
    }),
  })
  if (!res.ok) {
    console.error("get-recipe: openai call failed", { status: res.status, body: await res.text().catch(() => "") })
    return null
  }
  const data = await res.json().catch(() => null)
  const text = data?.choices?.[0]?.message?.content
  return typeof text === "string" ? text : null
}

/** Best-effort: never lets a logging failure break the actual request. */
async function logUsage(
  sbService: ReturnType<typeof createClient>,
  userId: string,
  provider: string,
  model: string,
  succeeded: boolean,
): Promise<void> {
  const { error } = await sbService
    .from("ai_usage_log")
    .insert({ user_id: userId, feature: "recipe_lookup", provider, model, succeeded, input_kind: "text" })
  if (error) console.error("get-recipe: failed to write ai_usage_log", { userId, provider, succeeded, error })
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
    if (!description) return fail("KITPAT_INVALID_INPUT", 400)

    // Forwards the caller's own Authorization header so auth.uid() inside
    // get_user_plan_limits resolves to this same user.
    const sbUser = createClient(URL, ANON, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    })

    // ------------------------------------------------------------- plan-limit check
    let allowed = true
    const { data: limits, error: limitsErr } = await sbUser.rpc("get_user_plan_limits", { p_user_id: user.id })
    if (limitsErr) {
      console.error("get-recipe: get_user_plan_limits failed, failing open", { userId: user.id, limitsErr })
    } else {
      const rawLimit = limits && typeof limits === "object" ? (limits as Record<string, unknown>).ai_calls_per_month : undefined
      const limit = typeof rawLimit === "number" ? rawLimit : null
      if (limit === null) {
        console.error("get-recipe: plans.limits has no ai_calls_per_month key, failing open", { userId: user.id, limits })
      } else if (limit !== -1) {
        const startOfMonth = new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth(), 1)).toISOString()
        const { count, error: countErr } = await sbService
          .from("ai_usage_log")
          .select("id", { count: "exact", head: true })
          .eq("user_id", user.id)
          .eq("feature", "recipe_lookup")
          .eq("succeeded", true)
          .gte("created_at", startOfMonth)
        if (countErr) {
          console.error("get-recipe: usage count failed, failing open", { userId: user.id, countErr })
        } else if ((count ?? 0) >= limit) {
          allowed = false
        }
      }
    }
    if (!allowed) return fail("KITPAT_PLAN_LIMIT_REACHED", 403)

    const provider: "anthropic" | "openai" | null = ANTHROPIC_API_KEY ? "anthropic" : OPENAI_API_KEY ? "openai" : null
    if (!provider) return fail("KITPAT_AI_NOT_CONFIGURED", 503)

    const model = provider === "anthropic" ? ANTHROPIC_MODEL : OPENAI_MODEL
    const prompt = buildPrompt(description)
    const raw = provider === "anthropic" ? await callAnthropic(prompt) : await callOpenAI(prompt)

    // Written AFTER the provider responds (or fails to), exactly once per
    // actual call this function makes -- succeeded reflects "did we get an
    // HTTP response" (billable), independent of whether that response then
    // parsed into a usable recipe. Mirrors analyze-food exactly.
    await logUsage(sbService, user.id, provider, model, raw !== null)

    if (raw === null) return fail("KITPAT_AI_UNAVAILABLE", 502)

    const recipe = parseRecipe(raw)
    if (recipe === null) {
      console.error("get-recipe: unparseable model output", { provider, raw })
      return fail("KITPAT_AI_UNAVAILABLE", 502)
    }

    const normalizedKey = await sbService.rpc("normalize_food_key", { p_text: recipe.title })
    const key = typeof normalizedKey.data === "string" ? normalizedKey.data : ""
    if (normalizedKey.error || key === "") {
      console.error("get-recipe: normalize_food_key failed", { userId: user.id, error: normalizedKey.error })
      return fail("KITPAT_AI_UNAVAILABLE", 502)
    }

    const { data: inserted, error: insertErr } = await sbService
      .from("recipes")
      .insert({
        normalized_key: key,
        title: recipe.title,
        cuisine: recipe.cuisine,
        serves: recipe.serves,
        prep_minutes: recipe.prep_minutes,
        cook_minutes: recipe.cook_minutes,
        ingredients: recipe.ingredients,
        steps: recipe.steps,
        notes: recipe.notes,
        source: "ai",
        ai_provider: provider,
        ai_model: model,
      })
      .select()
      .maybeSingle()

    let recipeRow = inserted

    if (insertErr) {
      // 23505 = unique_violation: another concurrent request already
      // inserted this exact title first. Not a failure -- re-select and
      // hand the caller the winning row, so a race never surfaces an
      // error to either party.
      if (insertErr.code === "23505") {
        const { data: existing, error: reselectErr } = await sbService
          .from("recipes")
          .select()
          .eq("normalized_key", key)
          .maybeSingle()
        if (reselectErr || !existing) {
          console.error("get-recipe: post-conflict re-select failed", { key, reselectErr })
          return fail("KITPAT_INTERNAL_ERROR", 500)
        }
        recipeRow = existing
      } else {
        console.error("get-recipe: recipe insert failed", { userId: user.id, insertErr })
        return fail("KITPAT_INTERNAL_ERROR", 500)
      }
    }

    return json({ ok: true, recipe: recipeRow })
  } catch (e) {
    console.error("get-recipe: unhandled error", e)
    return fail("KITPAT_INTERNAL_ERROR", 500)
  }
})
