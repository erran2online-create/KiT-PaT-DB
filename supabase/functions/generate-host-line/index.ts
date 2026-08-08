import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

/**
 * generate_host_line — one short host-copy line for live play moments.
 *
 * Reuses D1 ai-gateway stack: OpenAI gpt-4o-mini + public.ai_cache.
 * Cache first (especially game_start / number_called) so live number calls
 * do not hit the LLM every time. Winner/reminder still cache by inputs so
 * identical requests are free after the first miss.
 */

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")
const SERVICE =
  Deno.env.get("SUPA_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

const SITUATIONS = new Set(["number_called", "winner", "game_start", "reminder"])
const MODEL = "gpt-4o-mini"

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), {
    status: s,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...corsHeaders },
  })

function safeError(message: string, status: number) {
  return json({ error: message }, status)
}

function normalize(value: unknown, fallback: string): string {
  const s = typeof value === "string" ? value.trim().toLowerCase() : ""
  return s || fallback
}

function buildPrompt(input: {
  event_type: string
  language: string
  tone: string
  situation: string
}): string {
  const langHint =
    input.language === "hi"
      ? "Write in Hindi (Devanagari)."
      : input.language === "hinglish"
      ? "Write in playful Hinglish (Hindi-English mix)."
      : "Write in natural English."

  const situationHint: Record<string, string> = {
    game_start:
      "The host is kicking off a live party game. One energetic opening line that gets people ready.",
    number_called:
      "A number was just called in Tambola / housey. One short flavor line the host can say (do NOT invent a specific number).",
    winner:
      "Someone just won a prize. One short celebratory shout-out (no names needed).",
    reminder:
      "A gentle nudge to players who haven't marked their tickets / are distracted. One short line.",
  }

  return [
    `You write ONE short host line for an Indian social / kitty-party game.`,
    `Event type: ${input.event_type}.`,
    `Tone: ${input.tone}.`,
    situationHint[input.situation] || situationHint.game_start,
    langHint,
    `Rules: max 18 words. No quotes around the line. No markdown. No hashtags. Family-safe.`,
    `Return only the line.`,
  ].join("\n")
}

function cacheKey(input: {
  event_type: string
  language: string
  tone: string
  situation: string
}): string {
  // Stable key — number_called shares one line per tone/language, not per draw.
  return `host_line_${input.event_type}_${input.language}_${input.tone}_${input.situation}`
    .replace(/\s+/g, "_")
    .substring(0, 200)
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 200, headers: corsHeaders })
  if (req.method !== "POST") return safeError("Method Not Allowed", 405)

  if (!OPENAI_API_KEY) return safeError("AI service not configured", 503)
  if (!SUPABASE_URL || !SERVICE) return safeError("Backend not configured", 503)

  try {
    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const event_type = normalize(body.event_type, "tambola")
    const language = normalize(body.language, "en")
    const tone = normalize(body.tone, "warm")
    const situation = normalize(body.situation, "")

    if (!SITUATIONS.has(situation)) {
      return safeError(
        "situation must be one of: number_called, winner, game_start, reminder",
        400,
      )
    }

    const input = { event_type, language, tone, situation }
    const key = cacheKey(input)
    const sb = createClient(SUPABASE_URL, SERVICE, {
      auth: { persistSession: false, autoRefreshToken: false },
    })

    const { data: cached } = await sb
      .from("ai_cache")
      .select("output_text")
      .eq("cache_key", key)
      .maybeSingle()

    if (cached?.output_text) {
      return json({ line: cached.output_text, cached: true, cache_key: key })
    }

    const prompt = buildPrompt(input)
    const response = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: MODEL,
        messages: [{ role: "user", content: prompt }],
        max_tokens: 60,
        temperature: 0.85,
      }),
    })

    if (!response.ok) return safeError("AI provider error", 502)
    const data = await response.json()
    const line = String(data.choices?.[0]?.message?.content || "")
      .trim()
      .replace(/^["']|["']$/g, "")
    if (!line) return safeError("Empty AI response", 502)

    await sb.from("ai_cache").upsert(
      { cache_key: key, output_text: line, model: MODEL },
      { onConflict: "cache_key", ignoreDuplicates: true },
    )

    return json({ line, cached: false, cache_key: key })
  } catch {
    return safeError("Failed to generate host line", 500)
  }
})
