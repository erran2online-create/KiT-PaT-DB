import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

/**
 * ocr-bill — Google Cloud Vision TEXT_DETECTION → structured bill fields.
 *
 * Host reviews these values in the client; confirm_ocr_expense is the only
 * path that writes kitty_expenses. This function never inserts ledger rows.
 *
 * Body (any one image source):
 *   { public_id }           — Cloudinary public_id
 *   { cloudinary_url|image_url|url } — fetchable image URL
 *   { image_base64|image_data } — raw base64 or data-URI
 */

const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPA_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
const VISION_KEY = Deno.env.get("GOOGLE_VISION_API_KEY")
const CLOUD = Deno.env.get("CLOUDINARY_CLOUD_NAME")

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

type Confidence = "high" | "low" | "unclear"
type Field<T> = { value: T | null; confidence: Confidence }

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), {
    status: s,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...corsHeaders },
  })

function safeError(message: string, status: number) {
  return json({ error: message }, status)
}

function stripDataUri(input: string): string {
  const m = input.match(/^data:[^;]+;base64,(.+)$/i)
  return m ? m[1] : input.replace(/\s+/g, "")
}

function cloudinaryUrlFromPublicId(publicId: string): string | null {
  if (!CLOUD) return null
  const id = publicId.replace(/^\/+/, "")
  return `https://res.cloudinary.com/${CLOUD}/image/upload/${id}`
}

/** Parse "1,234.50" / "1234" → number (rupees, keep paise as fraction). */
function parseAmountToken(raw: string): number | null {
  const cleaned = raw.replace(/,/g, "").trim()
  if (!/^\d+(\.\d{1,2})?$/.test(cleaned)) return null
  const n = Number(cleaned)
  return Number.isFinite(n) && n > 0 ? n : null
}

const TOTAL_LABEL_SRC =
  String.raw`(?:grand\s*total|amount\s*(?:due|payable)|net\s*(?:amount|payable|total)|balance\s*due|total\s*amount|total\s*due|to\s*pay|\btotal\b)`

const CURRENCY_PREFIX_SRC = String.raw`(?:rs\.?|inr|₹)\s*`

function extractAmountsFromLine(line: string): number[] {
  const out: number[] = []
  // Labelled: Total: 450 / Grand Total Rs 1,200.00
  const labelled = new RegExp(
    `${TOTAL_LABEL_SRC}\\s*[:\\-]?\\s*${CURRENCY_PREFIX_SRC}?([\\d,]+(?:\\.\\d{1,2})?)`,
    "gi",
  )
  for (const m of line.matchAll(labelled)) {
    const n = parseAmountToken(m[1])
    if (n != null) out.push(n)
  }
  // Bare currency: Rs 450 / ₹1,200.00
  const currency = new RegExp(`${CURRENCY_PREFIX_SRC}([\\d,]+(?:\\.\\d{1,2})?)`, "gi")
  for (const m of line.matchAll(currency)) {
    const n = parseAmountToken(m[1])
    if (n != null) out.push(n)
  }
  return out
}

function lineHasTotalLabel(line: string): boolean {
  return new RegExp(TOTAL_LABEL_SRC, "i").test(line)
}

function scoreTotalCandidate(line: string, amount: number, lineIndex: number, lineCount: number): number {
  let score = amount / 1e6 // slight preference for larger when tied
  if (/grand\s*total/i.test(line)) score += 100
  else if (/amount\s*(?:due|payable)/i.test(line)) score += 80
  else if (/net\s*(?:amount|payable|total)/i.test(line)) score += 70
  else if (/balance\s*due|to\s*pay/i.test(line)) score += 60
  else if (/total/i.test(line)) score += 50
  else if (new RegExp(CURRENCY_PREFIX_SRC, "i").test(line)) score += 20
  // Totals often appear near the bottom of a bill
  score += (lineIndex / Math.max(lineCount - 1, 1)) * 10
  return score
}

function parseTotalAmount(rawText: string): Field<number> {
  const lines = rawText.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)
  type Cand = { amount: number; line: string; score: number }
  const cands: Cand[] = []
  const seen = new Set<string>()

  lines.forEach((line, i) => {
    const amounts = extractAmountsFromLine(line)
    // Also: next-line amount after a total label
    if (lineHasTotalLabel(line) && amounts.length === 0 && i + 1 < lines.length) {
      const nextAmts = extractAmountsFromLine(lines[i + 1])
      const bare = lines[i + 1].match(/^[\d,]+(?:\.\d{1,2})?$/)
      if (bare) {
        const n = parseAmountToken(bare[0])
        if (n != null) nextAmts.push(n)
      }
      for (const a of nextAmts) {
        const key = `${a}@${i}`
        if (seen.has(key)) continue
        seen.add(key)
        cands.push({ amount: a, line, score: scoreTotalCandidate(line, a, i, lines.length) })
      }
    }
    for (const a of amounts) {
      const key = `${a}@${i}`
      if (seen.has(key)) continue
      seen.add(key)
      cands.push({ amount: a, line, score: scoreTotalCandidate(line, a, i, lines.length) })
    }
  })

  // Prefer labelled totals; if none, fall back to currency amounts
  const labelled = cands.filter((c) => lineHasTotalLabel(c.line))
  const pool = labelled.length > 0
    ? labelled
    : cands.filter((c) => new RegExp(CURRENCY_PREFIX_SRC, "i").test(c.line))
  if (pool.length === 0) return { value: null, confidence: "unclear" }

  pool.sort((a, b) => b.score - a.score)
  const best = pool[0]
  const uniqueAmounts = new Set(pool.map((c) => c.amount))
  if (uniqueAmounts.size === 1 && (labelled.length === 1 || pool.length === 1)) {
    return { value: best.amount, confidence: "high" }
  }
  if (uniqueAmounts.size === 1) return { value: best.amount, confidence: "high" }
  return { value: best.amount, confidence: "low" }
}

const DATE_PATTERNS: RegExp[] = [
  /\b(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})\b/,
  /\b(\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})\b/,
  /\b(\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{2,4})\b/i,
  /\b((?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+\d{1,2},?\s+\d{2,4})\b/i,
]

function parseDate(rawText: string): Field<string> {
  const hits: string[] = []
  for (const line of rawText.split(/\r?\n/)) {
    for (const re of DATE_PATTERNS) {
      const m = line.match(re)
      if (m?.[1]) hits.push(m[1].trim())
    }
  }
  const unique = [...new Set(hits)]
  if (unique.length === 0) return { value: null, confidence: "unclear" }
  if (unique.length === 1) return { value: unique[0], confidence: "high" }
  return { value: unique[0], confidence: "low" }
}

function looksLikeNoiseVendor(line: string): boolean {
  if (line.length < 2) return true
  if (/^[\d\s\-\/\.]+$/.test(line)) return true
  if (/^(tel|phone|gst|gstin|invoice|bill\s*no|receipt|tax|cash|card)\b/i.test(line)) return true
  if (DATE_PATTERNS.some((re) => re.test(line)) && line.length < 20) return true
  if (new RegExp(CURRENCY_PREFIX_SRC, "i").test(line) && line.length < 16) return true
  return false
}

function parseVendorName(rawText: string): Field<string> {
  const lines = rawText.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)
  const candidates = lines.filter((l) => !looksLikeNoiseVendor(l)).slice(0, 5)
  if (candidates.length === 0) return { value: null, confidence: "unclear" }
  // Prefer first substantial line (typical merchant header)
  const first = candidates[0]
  if (candidates.length === 1 || first.length >= 3) {
    // Multiple header-ish lines → low if 2nd looks equally like a name
    if (candidates.length > 1 && candidates[1].length >= 4 && !/address|road|street|bangalore|mumbai|delhi/i.test(candidates[1])) {
      // Still take first; mark low when several plausible name lines
      const nameLike = candidates.filter((c) => /^[A-Za-z0-9][\w &.'-]{2,}$/.test(c))
      if (nameLike.length > 1) return { value: first, confidence: "low" }
    }
    return { value: first, confidence: "high" }
  }
  return { value: first, confidence: "low" }
}

function parseBillText(rawText: string) {
  const text = (rawText || "").trim()
  if (!text) {
    return {
      vendor_name: { value: null, confidence: "unclear" as Confidence },
      total_amount: { value: null, confidence: "unclear" as Confidence },
      date: { value: null, confidence: "unclear" as Confidence },
      raw_text: "",
    }
  }
  return {
    vendor_name: parseVendorName(text),
    total_amount: parseTotalAmount(text),
    date: parseDate(text),
    raw_text: text,
  }
}

type VisionImage =
  | { source: { imageUri: string } }
  | { content: string }

async function callVision(image: VisionImage): Promise<string> {
  const endpoint = `https://vision.googleapis.com/v1/images:annotate?key=${VISION_KEY}`
  const res = await fetch(endpoint, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      requests: [{
        image,
        features: [{ type: "TEXT_DETECTION" }],
      }],
    }),
  })
  const body = await res.json().catch(() => ({})) as Record<string, unknown>
  if (!res.ok) {
    const err = body.error as { message?: string } | undefined
    throw new Error(err?.message || `Vision API error (${res.status})`)
  }
  const responses = body.responses as Array<Record<string, unknown>> | undefined
  const first = responses?.[0] ?? {}
  if (first.error) {
    const err = first.error as { message?: string }
    throw new Error(err.message || "Vision annotation failed")
  }
  const annotations = first.textAnnotations as Array<{ description?: string }> | undefined
  const full = first.fullTextAnnotation as { text?: string } | undefined
  return (full?.text || annotations?.[0]?.description || "").trim()
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 200, headers: corsHeaders })
  if (req.method !== "POST") return safeError("Method Not Allowed", 405)

  try {
    const auth = req.headers.get("Authorization")
    if (!auth) return safeError("Unauthorized", 401)

    const sb = createClient(URL!, SERVICE!, { auth: { persistSession: false, autoRefreshToken: false } })
    const token = auth.replace(/^Bearer\s+/i, "")
    const { data: { user }, error: userErr } = await sb.auth.getUser(token)
    if (userErr || !user) return safeError("Unauthorized", 401)

    if (!VISION_KEY) return safeError("OCR service not configured", 503)

    const body = await req.json().catch(() => ({})) as Record<string, unknown>

    const publicId = body.public_id ? String(body.public_id) : null
    const imageUrl = [body.cloudinary_url, body.image_url, body.url]
      .map((v) => (typeof v === "string" && v ? v : null))
      .find(Boolean) as string | null
    const b64Raw = [body.image_base64, body.image_data]
      .map((v) => (typeof v === "string" && v ? v : null))
      .find(Boolean) as string | null

    let visionImage: VisionImage | null = null
    if (b64Raw) {
      visionImage = { content: stripDataUri(b64Raw) }
    } else if (imageUrl) {
      visionImage = { source: { imageUri: imageUrl } }
    } else if (publicId) {
      const built = cloudinaryUrlFromPublicId(publicId)
      if (!built) return safeError("Cloudinary not configured for public_id lookup", 503)
      visionImage = { source: { imageUri: built } }
    }

    if (!visionImage) {
      return safeError("Provide public_id, image_url/cloudinary_url, or image_base64", 400)
    }

    let rawText = ""
    try {
      rawText = await callVision(visionImage)
    } catch (e) {
      // If Vision rejects remote URL fetch, fall back to downloading and sending base64.
      if ("source" in visionImage) {
        const uri = visionImage.source.imageUri
        const imgRes = await fetch(uri)
        if (!imgRes.ok) return safeError("Could not fetch bill image", 400)
        const bytes = new Uint8Array(await imgRes.arrayBuffer())
        let binary = ""
        for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i])
        const content = btoa(binary)
        try {
          rawText = await callVision({ content })
        } catch {
          return safeError("OCR failed for this image", 502)
        }
      } else {
        return safeError(e instanceof Error ? "OCR failed for this image" : "OCR failed for this image", 502)
      }
    }

    // Always return the full structured object — unclear fields use value: null.
    return json(parseBillText(rawText))
  } catch {
    return safeError("Failed to process bill", 500)
  }
})
