import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const URL = Deno.env.get("SUPABASE_URL")
const SERVICE = Deno.env.get("SUPA_SERVICE_ROLE_KEY") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
const CLOUD = Deno.env.get("CLOUDINARY_CLOUD_NAME")
const KEY = Deno.env.get("CLOUDINARY_API_KEY")
const SECRET = Deno.env.get("CLOUDINARY_API_SECRET")

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

/** Never put secrets into client-facing error bodies. */
function safeError(message: string, status: number) {
  return json({ error: message }, status)
}

async function sha1Hex(v: string) {
  const d = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(v))
  return Array.from(new Uint8Array(d)).map((x) => x.toString(16).padStart(2, "0")).join("")
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 200, headers: corsHeaders })
  if (req.method !== "POST") return safeError("Method Not Allowed", 405)

  if (!CLOUD || !KEY || !SECRET) return safeError("Media service not configured", 503)

  try {
    const auth = req.headers.get("Authorization")
    if (!auth) return safeError("Unauthorized", 401)

    const sb = createClient(URL!, SERVICE!, { auth: { persistSession: false, autoRefreshToken: false } })
    const token = auth.replace(/^Bearer\s+/i, "")
    const { data: { user }, error: userErr } = await sb.auth.getUser(token)
    if (userErr || !user) return safeError("Unauthorized", 401)

    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const group_id = String(body.group_id || "")
    const event_id = body.event_id ? String(body.event_id) : null
    const asset_type = String(body.asset_type || "image")
    if (!group_id || !["image", "video"].includes(asset_type)) return safeError("Invalid request", 400)

    const { data: membership } = await sb.from("members").select("id").eq("group_id", group_id).eq("user_id", user.id).maybeSingle()
    const { data: group } = await sb.from("groups").select("host_id").eq("id", group_id).maybeSingle()
    if (!membership && group?.host_id !== user.id) return safeError("Forbidden", 403)

    if (event_id) {
      const { data: ev } = await sb.from("events").select("id,group_id").eq("id", event_id).maybeSingle()
      if (!ev || ev.group_id !== group_id) return safeError("Invalid event for group", 400)
    }

    const timestamp = Math.floor(Date.now() / 1000)
    const folder = event_id ? `events/${event_id}` : `groups/${group_id}`
    const public_id = `${user.id}_${crypto.randomUUID()}`
    // Cloudinary signed upload: alphabetical params + api_secret appended (never returned)
    const toSign = `folder=${folder}&public_id=${public_id}&timestamp=${timestamp}${SECRET}`
    const signature = await sha1Hex(toSign)

    return json({
      cloud_name: CLOUD,
      api_key: KEY,
      timestamp,
      folder,
      public_id,
      signature,
      resource_type: asset_type === "video" ? "video" : "image",
    })
  } catch {
    // Swallow details so secrets / stack traces never reach the client
    return safeError("Failed to create upload signature", 500)
  }
})
