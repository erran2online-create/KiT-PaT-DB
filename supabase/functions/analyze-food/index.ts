// P41/P42: a member describes a food/beverage as TEXT, a camera capture,
// or an uploaded image; this function asks an AI provider for approximate
// macros and returns them to the client. It does NOT save anything itself
// -- the client calls record_food_entry() separately with the values this
// function returns (letting the member review/adjust serving and choose
// whether to share to a group before it is persisted). NOT a health/
// medical feature.
//
// (P42 scope change, recorded here since the P41 migration file that
// originally called this "text-only, not a photo feature" is already
// applied to production and is therefore never edited: this function now
// accepts an image_url instead of/alongside description. A camera capture
// is just an upload from the device camera rather than the gallery -- it
// arrives here the same way a gallery upload does, as an image_url.)
//
// Two Postgres clients, same split as admin-write/admin-reveal:
//   - `sbService` (service_role) resolves the caller's identity from
//     their JWT (auth.getUser), does the plan-limit usage count, reads/
//     writes food_cache, computes normalize_food_key, and writes
//     ai_usage_log.
//   - `sbUser` forwards the caller's own Authorization header, so
//     get_user_plan_limits(p_user_id) -- which requires auth.uid() to
//     equal p_user_id for a non-admin caller -- resolves correctly.
//
// Plan limit: plans.limits carries 'ai_calls_per_month' (verified against
// the live plans rows: Free 10, Starter 50, Queen 500, Empress -1).
// -1 means unlimited, the same convention used by every other key in
// limits (max_parties_per_month, max_groups, ...) -- never enforced.
//
// Usage is counted from public.ai_usage_log (succeeded = true rows for
// this user, this UTC calendar month, feature='food_analysis'), NOT from
// food_entries -- food_entries can't work as the signal, since this
// function deliberately returns the estimate WITHOUT saving it, so a
// member who never calls record_food_entry would never be counted. The
// count check runs on whichever path will actually call the provider:
// always for an image request (there is no cache for images), or only on
// a cache MISS for a text request (a cache hit costs nothing and must
// never count against the cap). Check runs BEFORE calling the provider,
// so a member over their cap never triggers a billable request. The
// ai_usage_log row is written AFTER the provider responds -- succeeded
// reflects whether we got an HTTP response at all (billable), independent
// of whether the response text then parsed into usable macros. If the
// limits lookup is missing the key or fails outright, this function FAILS
// OPEN (proceeds, logs server-side) -- a broken lookup must never block a
// paying member.
//
// P42 cache: for a TEXT request (no image_url), the description+serving
// is normalized via public.normalize_food_key (the one place that
// normalisation rule lives -- see that function's own comment) and looked
// up in public.food_cache. A hit returns the cached macros immediately
// (cached: true), bumps hit_count/last_hit_at, and makes NO provider call
// and writes NO ai_usage_log row. A miss calls the provider as before,
// then best-effort upserts the result into food_cache -- a cache write
// failure is logged but never fails the member's request. Image lookups
// are NEVER cached (every photo is different).
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

// The same secret media-signature already reads -- image_url is only ever
// trusted if it points at this project's own Cloudinary cloud, never an
// arbitrary caller-supplied URL.
const CLOUDINARY_CLOUD_NAME = Deno.env.get("CLOUDINARY_CLOUD_NAME")

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

/** true only if image_url's host+path prefix matches this project's own Cloudinary cloud. */
function isOwnCloudinaryUrl(imageUrl: string): boolean {
  if (!CLOUDINARY_CLOUD_NAME) return false
  try {
    const u = new globalThis.URL(imageUrl)
    return u.protocol === "https:" && u.hostname === "res.cloudinary.com" && u.pathname.startsWith(`/${CLOUDINARY_CLOUD_NAME}/`)
  } catch {
    return false
  }
}

function buildPrompt(description: string | null, serving: string | null, hasImage: boolean): string {
  if (hasImage) {
    return [
      `You are a nutrition estimator. You are given a photo of a food or beverage${description ? ", plus a short hint from the person who took it" : ""}. Estimate its approximate macros for what is actually shown in the photo -- the photo is authoritative if a hint conflicts with it.`,
      "Respond with ONLY a single JSON object, no markdown fences, no commentary, no explanation -- just the JSON. The object MUST have exactly these keys:",
      '{"calories_kcal": number, "protein_g": number, "fat_g": number, "carbs_g": number, "serving": string, "confidence": number}',
      "calories_kcal/protein_g/fat_g/carbs_g are your best approximate numeric estimate for what is shown (use null for any you genuinely cannot estimate). serving is your best guess at the serving size shown, as a short string. confidence is a number from 0 to 1.",
      description ? `Hint from the member: ${description}` : "No hint was given -- rely on the photo alone.",
      serving ? `Stated serving: ${serving}` : "",
    ].filter(Boolean).join("\n")
  }
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

async function callAnthropic(prompt: string, imageUrl: string | null): Promise<string | null> {
  const content = imageUrl
    ? [
        { type: "image", source: { type: "url", url: imageUrl } },
        { type: "text", text: prompt },
      ]
    : prompt

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
      messages: [{ role: "user", content }],
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

async function callOpenAI(prompt: string, imageUrl: string | null): Promise<string | null> {
  const content = imageUrl
    ? [
        { type: "text", text: prompt },
        { type: "image_url", image_url: { url: imageUrl } },
      ]
    : prompt

  const res = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      messages: [{ role: "user", content }],
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

/** Best-effort: never lets a logging failure break the actual request. */
async function logUsage(
  sbService: ReturnType<typeof createClient>,
  userId: string,
  provider: string,
  model: string,
  succeeded: boolean,
  inputKind: "text" | "image",
): Promise<void> {
  const { error } = await sbService
    .from("ai_usage_log")
    .insert({ user_id: userId, feature: "food_analysis", provider, model, succeeded, input_kind: inputKind })
  if (error) console.error("analyze-food: failed to write ai_usage_log", { userId, provider, succeeded, inputKind, error })
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
    const description = typeof body.description === "string" && body.description.trim() !== "" ? body.description.trim() : null
    const serving = typeof body.serving === "string" && body.serving.trim() !== "" ? body.serving.trim() : null
    const imageUrl = typeof body.image_url === "string" && body.image_url.trim() !== "" ? body.image_url.trim() : null

    // Neither present is the only genuinely invalid combination: an
    // image_url may always be accompanied by a description as a hint
    // (the photo stays authoritative), so "both" is a normal, supported
    // request shape, not an error.
    if (!description && !imageUrl) return fail("KITPAT_INVALID_INPUT", 400)

    if (imageUrl && !isOwnCloudinaryUrl(imageUrl)) return fail("KITPAT_INVALID_INPUT", 400)

    const hasImage = imageUrl !== null
    const inputKind: "text" | "image" = hasImage ? "image" : "text"

    // Forwards the caller's own Authorization header so auth.uid() inside
    // get_user_plan_limits resolves to this same user (it requires
    // auth.uid() = p_user_id for a non-admin caller).
    const sbUser = createClient(URL, ANON, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    })

    // ------------------------------------------------------------ cache lookup
    // Text only. Never for an image -- every photo is different.
    if (!hasImage) {
      const { data: cacheKey, error: keyErr } = await sbService.rpc("normalize_food_key", {
        p_text: `${description} ${serving ?? ""}`,
      })
      if (keyErr) {
        console.error("analyze-food: normalize_food_key failed, skipping cache", { userId: user.id, keyErr })
      } else if (typeof cacheKey === "string" && cacheKey !== "") {
        const { data: cached, error: cacheErr } = await sbService
          .from("food_cache")
          .select("id, hit_count, serving, calories_kcal, protein_g, fat_g, carbs_g, ai_provider, ai_model")
          .eq("normalized_key", cacheKey)
          .maybeSingle()
        if (cacheErr) {
          console.error("analyze-food: cache lookup failed, falling through to provider", { userId: user.id, cacheErr })
        } else if (cached) {
          // Best-effort, read-then-write increment; a failure (or a lost
          // update under a concurrent hit on the same key) must never
          // affect the response -- hit_count is an informational counter,
          // not something correctness depends on.
          const { error: bumpErr } = await sbService
            .from("food_cache")
            .update({ hit_count: (cached.hit_count ?? 0) + 1, last_hit_at: new Date().toISOString() })
            .eq("id", cached.id)
          if (bumpErr) console.error("analyze-food: cache hit_count bump failed", { cacheId: cached.id, bumpErr })

          return json({
            ok: true,
            calories_kcal: cached.calories_kcal,
            protein_g: cached.protein_g,
            fat_g: cached.fat_g,
            carbs_g: cached.carbs_g,
            serving: cached.serving ?? serving,
            confidence: null,
            ai_provider: cached.ai_provider,
            ai_model: cached.ai_model,
            cached: true,
          })
        }
      }
    }

    // ------------------------------------------------------- plan-limit check
    // Runs on whichever path is about to actually call the provider:
    // always for an image request, or here for a text cache MISS.
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
          .from("ai_usage_log")
          .select("id", { count: "exact", head: true })
          .eq("user_id", user.id)
          .eq("feature", "food_analysis")
          .eq("succeeded", true)
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

    const model = provider === "anthropic" ? ANTHROPIC_MODEL : OPENAI_MODEL
    const prompt = buildPrompt(description, serving, hasImage)
    const raw = provider === "anthropic" ? await callAnthropic(prompt, imageUrl) : await callOpenAI(prompt, imageUrl)

    // Written AFTER the provider responds (or fails to), exactly once per
    // actual call this function makes -- see this file's header for why
    // succeeded reflects "did we get an HTTP response" (billable),
    // independent of whether that response then parsed into usable
    // macros.
    await logUsage(sbService, user.id, provider, model, raw !== null, inputKind)

    if (raw === null) return fail("KITPAT_AI_UNAVAILABLE", 502)

    const macros = parseMacros(raw)
    if (macros === null) {
      console.error("analyze-food: unparseable model output", { provider, raw })
      return fail("KITPAT_AI_UNAVAILABLE", 502)
    }

    // Cache the result -- text misses only, never an image lookup. A
    // cache write failure is logged but must never fail the request.
    if (!hasImage) {
      const { data: cacheKey } = await sbService.rpc("normalize_food_key", { p_text: `${description} ${serving ?? ""}` })
      if (typeof cacheKey === "string" && cacheKey !== "") {
        const { error: upsertErr } = await sbService.from("food_cache").upsert(
          {
            normalized_key: cacheKey,
            sample_description: description,
            serving: macros.serving ?? serving,
            calories_kcal: macros.calories_kcal,
            protein_g: macros.protein_g,
            fat_g: macros.fat_g,
            carbs_g: macros.carbs_g,
            ai_provider: provider,
            ai_model: model,
          },
          { onConflict: "normalized_key" },
        )
        if (upsertErr) console.error("analyze-food: food_cache upsert failed (non-fatal)", { cacheKey, upsertErr })
      }
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
      ai_model: model,
      cached: false,
    })
  } catch (e) {
    console.error("analyze-food: unhandled error", e)
    return fail("KITPAT_INTERNAL_ERROR", 500)
  }
})
