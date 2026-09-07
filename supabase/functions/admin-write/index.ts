// AP1: single secure write path for the 7 admin-editable content tables
// (badge_definitions, invite_templates, plans, game_theme_packs,
// festival_themes, greeting_variants, tambola_variants). RLS on all 7
// stays client-read-only -- this function holds SUPABASE_SERVICE_ROLE_KEY
// server-side and is the only thing that ever writes to them on the
// client's behalf. The admin frontend must NEVER hold service_role.
//
// Two Postgres clients are used deliberately, for two different jobs:
//   - `sbUser` forwards the caller's own Authorization header, so
//     PostgREST authenticates as that specific user and auth.jwt()/
//     auth.uid() resolve correctly inside admin_can_write() -- this is
//     the single source of truth for "may this admin write this table".
//   - `sbService` authenticates as service_role itself (bypasses RLS by
//     design) and does the actual table read/write plus the
//     log_admin_action call, whose internal guard requires
//     current_setting('role') = 'service_role'.
//
// Never trust a client-supplied role or email -- both are re-derived
// server-side from the verified JWT (auth.getUser) and the admins table.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SUPA_SERVICE_ROLE_KEY")
const ANON = Deno.env.get("SUPABASE_ANON_KEY")

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

/** Never put raw exception text / Postgres error detail in a client-facing body. */
function fail(code: string, status: number) {
  return json({ error: code }, status)
}

// The 7 admin-editable content tables, and the column each is actually
// keyed by. tambola_variants is the one exception in this set: its
// primary key is `key` (text), not `id` -- every other table here uses a
// uuid `id` primary key.
const PK_COLUMN: Record<string, string> = {
  badge_definitions: "id",
  invite_templates: "id",
  plans: "id",
  game_theme_packs: "id",
  festival_themes: "id",
  greeting_variants: "id",
  tambola_variants: "key",
  festival_cards: "id",
  promo_cards: "id",
  coupons: "id",
  coupon_targets: "id",
}
const ALLOWED_TABLES = Object.keys(PK_COLUMN)
const ALLOWED_OPS = ["insert", "update", "delete"] as const
type Op = (typeof ALLOWED_OPS)[number]

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
    if (userErr || !user || !user.email) return fail("KITPAT_UNAUTHENTICATED", 401)

    // Resolve the caller's admin record ourselves (service client, bypasses
    // RLS) rather than trusting anything the client sent.
    const { data: adminRow, error: adminErr } = await sbService
      .from("admins")
      .select("id, role, is_active")
      .eq("email", user.email)
      .maybeSingle()
    if (adminErr || !adminRow || !adminRow.is_active) return fail("KITPAT_ADMIN_ONLY", 403)

    const body = (await req.json().catch(() => ({}))) as Record<string, unknown>
    const table = String(body.table || "")
    const op = String(body.op || "") as Op
    const id = body.id != null ? String(body.id) : null
    const payload = body.payload

    if (!ALLOWED_TABLES.includes(table)) return fail("KITPAT_TABLE_NOT_ALLOWED", 400)
    if (!ALLOWED_OPS.includes(op)) return fail("KITPAT_INVALID_OP", 400)

    // Role gate (documented in one place by admin_can_write; re-checked here
    // for the specific error code, since a single boolean can't distinguish
    // "no admin at all" from "admin but wrong role for this table"):
    //   member       -> read only, every write rejected
    //   org_admin    -> write everything except plans
    //   owner        -> write everything
    if (adminRow.role === "member") return fail("KITPAT_INSUFFICIENT_ROLE", 403)
    if (table === "plans" && adminRow.role !== "owner") return fail("KITPAT_INSUFFICIENT_ROLE", 403)

    // Single source of truth, re-checked via the user's own JWT so
    // auth.jwt()/is_admin() resolve correctly -- defense in depth against
    // the two manual checks above ever drifting from the DB-side rule.
    const sbUser = createClient(URL, ANON, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    })
    const { data: canWrite, error: canWriteErr } = await sbUser.rpc("admin_can_write", { p_table: table })
    if (canWriteErr || canWrite !== true) return fail("KITPAT_INSUFFICIENT_ROLE", 403)

    if ((op === "update" || op === "delete") && !id) return fail("KITPAT_ID_REQUIRED", 400)
    if ((op === "insert" || op === "update") && (typeof payload !== "object" || payload === null || Array.isArray(payload))) {
      return fail("KITPAT_PAYLOAD_REQUIRED", 400)
    }

    const pkCol = PK_COLUMN[table]

    let beforeRow: Record<string, unknown> | null = null
    if (op !== "insert") {
      // id is guaranteed non-null here: the update/delete branch above
      // already rejected a missing id with KITPAT_ID_REQUIRED.
      const { data, error } = await sbService.from(table).select("*").eq(pkCol, id as string).maybeSingle()
      if (error) {
        console.error("admin-write: before-read failed", { table, op, id, error })
        return fail("KITPAT_WRITE_FAILED", 500)
      }
      if (!data) return fail("KITPAT_NOT_FOUND", 404)
      beforeRow = data
    }

    let afterRow: Record<string, unknown> | null = null
    if (op === "insert") {
      const { data, error } = await sbService.from(table).insert(payload as Record<string, unknown>).select().single()
      if (error) {
        console.error("admin-write: insert failed", { table, error })
        return fail("KITPAT_WRITE_FAILED", 500)
      }
      afterRow = data
    } else if (op === "update") {
      const { data, error } = await sbService.from(table).update(payload as Record<string, unknown>).eq(pkCol, id as string).select().single()
      if (error) {
        console.error("admin-write: update failed", { table, id, error })
        return fail("KITPAT_WRITE_FAILED", 500)
      }
      afterRow = data
    } else {
      const { error } = await sbService.from(table).delete().eq(pkCol, id as string)
      if (error) {
        console.error("admin-write: delete failed", { table, id, error })
        return fail("KITPAT_WRITE_FAILED", 500)
      }
      afterRow = null // nothing exists post-delete; `before` already captured the final state
    }

    const resolvedId = id ?? (afterRow ? String(afterRow[pkCol]) : null)

    const { error: logErr } = await sbService.rpc("log_admin_action", {
      p_action: `${op}:${table}`,
      p_target_type: table,
      p_target_id: resolvedId,
      p_before: beforeRow,
      p_after: afterRow,
      p_is_sensitive_reveal: false,
      p_revealed_field: null,
      p_revealed_subject: null,
      p_actor_admin_id: adminRow.id,
      p_actor_email: user.email,
    })
    // The content write already succeeded -- a logging hiccup shouldn't
    // leave the admin unsure whether their edit saved. Surface it in
    // server logs only.
    if (logErr) console.error("admin-write: log_admin_action failed", { table, op, resolvedId, logErr })

    return json({ ok: true, table, op, id: resolvedId, before: beforeRow, after: afterRow })
  } catch (e) {
    console.error("admin-write: unhandled error", e)
    return fail("KITPAT_INTERNAL_ERROR", 500)
  }
})
