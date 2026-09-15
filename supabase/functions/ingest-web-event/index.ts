// P47: page-view analytics for the kitpat.in marketing site. A marketing
// visitor has no member JWT, so this cannot go through ingest-event (P45)
// -- that function's auth is NOT relaxed for this. This is instead the
// ONE endpoint in the project that accepts unauthenticated writes, so
// every control below exists to compensate for that:
//   - a shared secret header (X-KitPat-Web-Key / WEB_ANALYTICS_KEY) --
//     anyone without it is rejected outright, before anything else runs;
//   - accepts exactly one event name ("page_view") -- this is not a
//     general-purpose anonymous ingest, and never will be by accident;
//   - a body-size cap and a simple per-(country, route)-per-minute rate
//     limit, so an open endpoint (even a keyed one -- the key can leak)
//     is never a free write primitive;
//   - no IP address, user agent, or device id is ever read or stored.
//     Country/region/city (as reported by the caller -- see below) is the
//     granularity; anything finer starts tracking a person rather than
//     measuring a market.
//
// Geo fields (country/region/city) are supplied by the CALLER -- expected
// to be a Vercel edge function on the marketing site reading Vercel's own
// geo headers (req.geo / x-vercel-ip-country etc.) and forwarding them
// here as plain strings. This function treats them as completely
// untrusted input: no format validation beyond a 120-char cap, since a
// wrong or spoofed country string only pollutes an analytics rollup, not
// anything security- or money-relevant.
//
// Writes to public.audit_events with user_id NULL, source='web'. That
// table's own "deny client audit events" RLS policy (P45, untouched here)
// already blocks every authenticated/anon write -- this function's
// service_role client is the only path in, exactly like ingest-event's.
//
// occurred_at clamping (missing/unparseable/>24h from server time falls
// back to server now()) reuses ingest-event's own resolveOccurredAt logic
// verbatim -- the same data-quality concern (a wrong client clock
// poisoning the timeline) applies identically to this table's same
// column, so this is a direct reuse of an already-established pattern,
// not a new one invented for this function.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPA_SERVICE_ROLE_KEY")

// New secret, not previously used anywhere in this repo -- must be set on
// this function before it can accept any write. See this PR's description.
const WEB_ANALYTICS_KEY = Deno.env.get("WEB_ANALYTICS_KEY")

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-kitpat-web-key",
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

// A page_view body is tiny (a handful of short strings); this is generous
// headroom, not a real ceiling anyone legitimate could hit.
const MAX_BODY_BYTES = 4 * 1024
const MAX_FIELD_LEN = 120
const ONE_DAY_MS = 24 * 60 * 60 * 1000

// Deliberately generous: this exists to stop an open endpoint from being a
// free write primitive, not to police real marketing traffic spikes on a
// popular page/country pair.
const RATE_LIMIT_PER_MINUTE = 300

function cap(v: unknown): string | null {
  if (typeof v !== "string") return null
  const trimmed = v.trim()
  return trimmed === "" ? null : trimmed.slice(0, MAX_FIELD_LEN)
}

/** Same clamp ingest-event uses for the same column: a wrong device/edge clock must not poison the timeline. */
function resolveOccurredAt(raw: unknown): string {
  const now = new Date()
  if (typeof raw !== "string") return now.toISOString()
  const parsed = new Date(raw)
  if (Number.isNaN(parsed.getTime())) return now.toISOString()
  if (Math.abs(now.getTime() - parsed.getTime()) > ONE_DAY_MS) return now.toISOString()
  return parsed.toISOString()
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 200, headers: corsHeaders })
  if (req.method !== "POST") return fail("KITPAT_METHOD_NOT_ALLOWED", 405)
  if (!URL || !SERVICE) return fail("KITPAT_NOT_CONFIGURED", 503)
  if (!WEB_ANALYTICS_KEY) return fail("KITPAT_NOT_CONFIGURED", 503)

  // The one gate that runs before anything else, including reading the
  // body: no key, no further work.
  const suppliedKey = req.headers.get("X-KitPat-Web-Key") || ""
  if (!suppliedKey || suppliedKey !== WEB_ANALYTICS_KEY) {
    return fail("KITPAT_UNAUTHORIZED", 401)
  }

  try {
    const rawBody = await req.text()
    if (new TextEncoder().encode(rawBody).length > MAX_BODY_BYTES) return fail("KITPAT_PAYLOAD_TOO_LARGE", 413)

    let body: Record<string, unknown>
    try {
      body = rawBody ? JSON.parse(rawBody) : {}
    } catch {
      return fail("KITPAT_INVALID_INPUT", 400)
    }
    if (typeof body !== "object" || body === null || Array.isArray(body)) return fail("KITPAT_INVALID_INPUT", 400)

    // Exactly one event name -- this is not a general-purpose ingest.
    if (body.event !== "page_view") return fail("KITPAT_INVALID_INPUT", 400)

    const route = cap(body.route)
    const country = cap(body.country)
    if (!route || !country) return fail("KITPAT_INVALID_INPUT", 400)

    const region = cap(body.region)
    const city = cap(body.city)
    const referrer = cap(body.referrer)
    const occurredAt = resolveOccurredAt(body.occurred_at)

    const sbService = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } })

    // Past this point, every failure is swallowed: a failed analytics
    // write must never break the marketing page.
    try {
      // Simple per-(country, route)-per-minute counter, read straight
      // from audit_events itself -- no new table needed. An open,
      // key-protected endpoint must still not be a free write primitive
      // (the key can leak); this bounds it without policing legitimate
      // traffic spikes.
      const oneMinuteAgo = new Date(Date.now() - 60_000).toISOString()
      const { count: recentCount, error: rlErr } = await sbService
        .from("audit_events")
        .select("id", { count: "exact", head: true })
        .eq("event_name", "page_view")
        .eq("source", "web")
        .gte("occurred_at", oneMinuteAgo)
        .contains("properties", { country, route })

      if (rlErr) {
        console.error("ingest-web-event: rate-limit count failed, proceeding", { country, route, rlErr })
      } else if ((recentCount ?? 0) >= RATE_LIMIT_PER_MINUTE) {
        console.log("ingest-web-event: rate limit hit, dropping", { country, route, recentCount })
        return json({ ok: true })
      }

      const { error: insertErr } = await sbService.from("audit_events").insert({
        user_id: null,
        event_name: "page_view",
        occurred_at: occurredAt,
        source: "web",
        properties: { route, country, region, city, referrer },
      })
      if (insertErr) console.error("ingest-web-event: insert failed", { country, route, insertErr })

      return json({ ok: true })
    } catch (e) {
      console.error("ingest-web-event: unhandled error past validation", { country, route, e })
      return json({ ok: true })
    }
  } catch (e) {
    console.error("ingest-web-event: unhandled error", e)
    return fail("KITPAT_INTERNAL_ERROR", 500)
  }
})
