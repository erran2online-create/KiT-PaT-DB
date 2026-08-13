import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

/**
 * P24: notify-party-created
 * Fan out a Telegram message to every group member with telegram_id when a
 * party/event is created. Reuses TELEGRAM_BOT_TOKEN sendMessage pattern from
 * send-telegram-otp.
 *
 * Auth: caller's JWT must be the group host (is_group_host / groups.host_id).
 * Body: { event_id: uuid }
 */

const BOT = Deno.env.get("TELEGRAM_BOT_TOKEN");
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE =
  Deno.env.get("SUPA_SERVICE_ROLE_KEY") ||
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), {
    status: s,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...corsHeaders,
    },
  });

function safeError(message: string, status: number) {
  return json({ error: message }, status);
}

function formatPartyDate(iso: string | null): string {
  if (!iso) return "TBD";
  try {
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    return d.toLocaleString("en-IN", {
      timeZone: "Asia/Kolkata",
      weekday: "short",
      year: "numeric",
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return iso;
  }
}

function buildMessage(input: {
  title: string;
  party_date: string | null;
  venue: string | null;
  group_name: string | null;
}): string {
  const lines = [
    "🎉 New KiT-PaT party!",
    "",
    `Party: ${input.title}`,
    `When: ${formatPartyDate(input.party_date)}`,
    `Venue: ${input.venue?.trim() || "TBD"}`,
  ];
  if (input.group_name) lines.push(`Group: ${input.group_name}`);
  lines.push("", "See you there!");
  return lines.join("\n");
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }
  if (req.method !== "POST") return safeError("Method Not Allowed", 405);

  if (!BOT) return safeError("Telegram not configured", 503);
  if (!SUPABASE_URL || !SERVICE) return safeError("Backend not configured", 503);

  const auth = req.headers.get("Authorization");
  if (!auth) return safeError("Unauthorized", 401);

  const sb = createClient(SUPABASE_URL, SERVICE, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const token = auth.replace(/^Bearer\s+/i, "");
  const {
    data: { user },
    error: userErr,
  } = await sb.auth.getUser(token);
  if (userErr || !user) return safeError("Unauthorized", 401);

  let body: { event_id?: string };
  try {
    body = await req.json();
  } catch {
    return safeError("Invalid JSON", 400);
  }

  const event_id = String(body.event_id || "").trim();
  if (!event_id) return safeError("event_id is required", 400);

  const { data: ev, error: evErr } = await sb
    .from("events")
    .select("id, title, party_date, venue, group_id, created_by")
    .eq("id", event_id)
    .maybeSingle();

  if (evErr || !ev) return safeError("Event not found", 404);

  const { data: group, error: gErr } = await sb
    .from("groups")
    .select("id, name, host_id")
    .eq("id", ev.group_id)
    .maybeSingle();

  if (gErr || !group) return safeError("Group not found", 404);

  // Only the group host (party creator context) may trigger notify
  if (group.host_id !== user.id) {
    return safeError("Host access required", 403);
  }

  const { data: members, error: mErr } = await sb
    .from("members")
    .select("user_id, users!inner(id, name, telegram_id)")
    .eq("group_id", ev.group_id);

  if (mErr) return safeError("Failed to load members", 500);

  type MemberRow = {
    user_id: string;
    users:
      | { id: string; name: string | null; telegram_id: string | null }
      | { id: string; name: string | null; telegram_id: string | null }[];
  };

  const text = buildMessage({
    title: ev.title || "Untitled party",
    party_date: ev.party_date,
    venue: ev.venue,
    group_name: group.name,
  });

  const results: Array<{
    user_id: string;
    name: string | null;
    status: "sent" | "skipped_no_telegram" | "failed";
    message_id?: number | null;
  }> = [];

  for (const row of (members || []) as MemberRow[]) {
    const u = Array.isArray(row.users) ? row.users[0] : row.users;
    const tg = u?.telegram_id?.trim();
    if (!tg) {
      results.push({
        user_id: row.user_id,
        name: u?.name ?? null,
        status: "skipped_no_telegram",
      });
      continue;
    }

    try {
      const r = await fetch(`https://api.telegram.org/bot${BOT}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: tg, text }),
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok || data.ok === false) {
        results.push({
          user_id: row.user_id,
          name: u?.name ?? null,
          status: "failed",
        });
      } else {
        results.push({
          user_id: row.user_id,
          name: u?.name ?? null,
          status: "sent",
          message_id: data.result?.message_id ?? null,
        });
      }
    } catch {
      results.push({
        user_id: row.user_id,
        name: u?.name ?? null,
        status: "failed",
      });
    }
  }

  const sent = results.filter((x) => x.status === "sent").length;
  const skipped = results.filter((x) => x.status === "skipped_no_telegram").length;
  const failed = results.filter((x) => x.status === "failed").length;

  return json({
    success: true,
    event_id,
    sent,
    skipped,
    failed,
    recipients: results,
  });
});
