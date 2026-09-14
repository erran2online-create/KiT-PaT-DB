// P45/P45.1: analytics ingest for the member app. Previously never built --
// `supabase functions deploy ingest-event` 404'd, flagged as L34 in the
// consumer app's own BACKEND-CONTRACT.md (a separate repo this one cannot
// see). The exact contract was supplied verbatim in the P45.1 prompt, from
// that repo's "L34 -- analytics ingest" section and its
// src/analytics/events.ts call site:
//
//   POST /functions/v1/ingest-event
//   Body: { event, occurred_at, route, props, error? }
//   Events: signup_completed, group_created, invite_shared, invite_redeemed,
//           party_created, contribution_recorded, game_started,
//           game_completed, client_error
//   props carries ids/enums/counts only -- never phone numbers, names,
//   titles or amounts (already stripped client-side in that repo's
//   src/analytics/events.ts sanitize()). This function does not re-scan
//   props for PII: the client is the source of truth for that scrub, per
//   its own FRONTEND_CONTRACT.md ("Never include OTP, secrets, full
//   payment credentials or unnecessary PII").
//   error, when present: { name, message (<=300 chars), stack
//   (<=4000 chars) } -- the client's own caps, enforced again here
//   server-side since a client-side cap is not a guarantee.
//
// It is ONE event per request (not a batch, per the P45.1 correction --
// the original P45 batching requirement was wrong and is not built).
//
// public.analytics_event_catalog and public.audit_events were both read in
// full from 20260801140136_remote_schema.sql before writing this:
//   - analytics_event_catalog (PK event_name, category, description,
//     required_properties text[], contains_pii boolean, created_at) is a
//     read-only taxonomy table -- "authenticated read analytics taxonomy"
//     is its only policy, no write policy of any kind. required_properties/
//     contains_pii are documentation metadata for downstream consumers of
//     the catalog; this function does not enforce required_properties or
//     gate on contains_pii, since neither was asked for -- it validates
//     event_name existence only, per the task.
//   - audit_events (id bigint identity, occurred_at, user_id/group_id/
//     event_id/session_id all nullable FKs ON DELETE SET NULL, event_name,
//     source DEFAULT 'app', request_id, properties jsonb DEFAULT '{}') has
//     an explicit "deny client audit events" USING(false) policy for BOTH
//     authenticated and anon -- confirming a client cannot write it
//     directly and this service_role function is the only path in.
//
// NOTE, flagged rather than worked around: no migration in this repo seeds
// analytics_event_catalog (this task is function-only, no migration
// allowed) -- grepping every migration for "INSERT INTO.*analytics_event_
// catalog" returns nothing, the same situation as feature_flags' 25 rows.
// If the 9 event names above are not already present as live catalog rows,
// every event will be silently dropped (by design, per the "unknown event_
// name: drop silently" requirement) until the catalog is seeded elsewhere.
//
// There is no group_id/event_id/session_id at the top level of the
// request body. Per the P45.1 correction: if props carries id-like keys
// matching audit_events' nullable FK column names (group_id/event_id/
// session_id) and they look like UUIDs, they are opportunistically lifted
// to those top-level columns (which already have indexes -- idx_audit_
// events_group/_session -- for exactly this use). properties always keeps
// the original props verbatim regardless of whether a lift is attempted or
// succeeds, so a lifted id that turns out not to exist (FK violation,
// Postgres 23503) is never lost: the insert is retried with just that
// column nulled, and the value remains readable from properties.
//
// Every failure past the malformed-request/auth/size gates -- unknown
// event_name, a DB insert error, a lift that doesn't pan out -- returns
// 200. The client (supabase.functions.invoke, fire-and-forget) must never
// see an analytics failure. Stable KITPAT_* codes are used only for the
// genuinely malformed-request cases (bad JSON, missing/invalid required
// fields, oversized body) and for the auth rejection, matching every other
// function's convention in this repo.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPA_SERVICE_ROLE_KEY")

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

// Generous for a { event, occurred_at, route, props, error? } body -- the
// biggest legitimate payload is a client_error event with a full 4000-char
// stack plus a 300-char message, well under this.
const MAX_BODY_BYTES = 20 * 1024

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const LIFTABLE_FK_COLUMNS = ["group_id", "event_id", "session_id"] as const
type LiftableFkColumn = (typeof LIFTABLE_FK_COLUMNS)[number]

function liftId(props: Record<string, unknown>, key: LiftableFkColumn): string | null {
  const v = props[key]
  return typeof v === "string" && UUID_RE.test(v) ? v : null
}

const ONE_DAY_MS = 24 * 60 * 60 * 1000

/** Client-supplied occurred_at, clamped to server time if missing, unparseable, or more than 24h off -- a wrong device clock must not poison the timeline. */
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

  try {
    const authHeader = req.headers.get("Authorization") || ""
    const token = authHeader.replace(/^Bearer\s+/i, "").trim()
    if (!token) return fail("KITPAT_UNAUTHENTICATED", 401)

    const sb = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } })

    const { data: { user }, error: userErr } = await sb.auth.getUser(token)
    if (userErr || !user) return fail("KITPAT_UNAUTHENTICATED", 401)

    const rawBody = await req.text()
    if (new TextEncoder().encode(rawBody).length > MAX_BODY_BYTES) return fail("KITPAT_PAYLOAD_TOO_LARGE", 413)

    let body: Record<string, unknown>
    try {
      body = rawBody ? JSON.parse(rawBody) : {}
    } catch {
      return fail("KITPAT_INVALID_INPUT", 400)
    }
    if (typeof body !== "object" || body === null || Array.isArray(body)) return fail("KITPAT_INVALID_INPUT", 400)

    const eventName = typeof body.event === "string" ? body.event.trim() : ""
    if (!eventName) return fail("KITPAT_INVALID_INPUT", 400)

    const rawProps = body.props
    const props: Record<string, unknown> =
      typeof rawProps === "object" && rawProps !== null && !Array.isArray(rawProps) ? (rawProps as Record<string, unknown>) : {}

    const occurredAt = resolveOccurredAt(body.occurred_at)

    const properties: Record<string, unknown> = {
      ...props,
      route: typeof body.route === "string" ? body.route.slice(0, 2000) : undefined,
    }

    const rawError = body.error
    if (typeof rawError === "object" && rawError !== null && !Array.isArray(rawError)) {
      const e = rawError as Record<string, unknown>
      properties.error = {
        name: typeof e.name === "string" ? e.name : undefined,
        message: typeof e.message === "string" ? e.message.slice(0, 300) : undefined,
        stack: typeof e.stack === "string" ? e.stack.slice(0, 4000) : undefined,
      }
    }

    // Past this point, every failure is swallowed: the client is
    // fire-and-forget and must never see an analytics failure.
    try {
      const { data: catalogRow, error: catalogErr } = await sb
        .from("analytics_event_catalog")
        .select("event_name")
        .eq("event_name", eventName)
        .maybeSingle()

      if (catalogErr) {
        console.error("ingest-event: catalog lookup failed", { eventName, catalogErr })
        return json({ ok: true })
      }
      if (!catalogRow) {
        console.log("ingest-event: dropped unknown event_name", { eventName, userId: user.id })
        return json({ ok: true })
      }

      const row: Record<string, unknown> = {
        user_id: user.id,
        event_name: eventName,
        occurred_at: occurredAt,
        source: "app",
        properties,
        group_id: liftId(props, "group_id"),
        event_id: liftId(props, "event_id"),
        session_id: liftId(props, "session_id"),
      }

      // Up to one retry per lifted FK column: a lifted id that doesn't
      // exist gets nulled out of the top-level column (it stays intact in
      // properties, set above regardless of lift outcome) and the insert
      // is retried, rather than the whole event being dropped.
      for (let attempt = 0; attempt <= LIFTABLE_FK_COLUMNS.length; attempt++) {
        const { error: insertErr } = await sb.from("audit_events").insert(row)
        if (!insertErr) break

        if (insertErr.code === "23503") {
          const offending = LIFTABLE_FK_COLUMNS.find((col) => row[col] && insertErr.message.includes(col))
          if (offending) {
            row[offending] = null
            continue
          }
          // Couldn't identify which column -- null all lifted ids and try once more.
          for (const col of LIFTABLE_FK_COLUMNS) row[col] = null
          continue
        }

        console.error("ingest-event: insert failed", { eventName, userId: user.id, insertErr })
        break
      }

      return json({ ok: true })
    } catch (e) {
      console.error("ingest-event: unhandled error past validation", { eventName, userId: user.id, e })
      return json({ ok: true })
    }
  } catch (e) {
    console.error("ingest-event: unhandled error", e)
    return fail("KITPAT_INTERNAL_ERROR", 500)
  }
})
