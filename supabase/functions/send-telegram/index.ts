import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

/**
 * P12: plain Telegram send for n8n (reminders / recaps).
 * Reuses TELEGRAM_BOT_TOKEN + KITPAT_SUPPORT_CHAT_ID from send-telegram-otp.
 * Auth: service_role Bearer (or matching apikey). Not for public browser clients.
 */
const BOT = Deno.env.get("TELEGRAM_BOT_TOKEN");
const DEFAULT_CHAT = Deno.env.get("KITPAT_SUPPORT_CHAT_ID");

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

function isServiceRole(req: Request): boolean {
  const auth = req.headers.get("Authorization") ?? "";
  const apikey = req.headers.get("apikey") ?? "";
  const bearer = auth.toLowerCase().startsWith("bearer ")
    ? auth.slice(7).trim()
    : "";
  const token = bearer || apikey;
  if (!token) return false;
  try {
    const payload = JSON.parse(atob(token.split(".")[1] ?? ""));
    return payload.role === "service_role";
  } catch {
    return false;
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "Method Not Allowed" }, 405);
  if (!isServiceRole(req)) return json({ error: "service_role required" }, 401);
  if (!BOT) return json({ error: "TELEGRAM_BOT_TOKEN not configured" }, 500);

  let body: { text?: string; chat_id?: string | number; parse_mode?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  const text = String(body.text ?? "").trim();
  if (!text) return json({ error: "text is required" }, 400);
  const chat_id = body.chat_id ?? DEFAULT_CHAT;
  if (chat_id === undefined || chat_id === null || chat_id === "") {
    return json({ error: "chat_id required (or set KITPAT_SUPPORT_CHAT_ID)" }, 400);
  }

  const payload: Record<string, unknown> = { chat_id, text };
  if (body.parse_mode) payload.parse_mode = body.parse_mode;

  const r = await fetch(`https://api.telegram.org/bot${BOT}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok || data.ok === false) {
    return json(
      { error: "Telegram send failed", detail: data },
      502,
    );
  }
  return json({ success: true, message_id: data.result?.message_id ?? null });
});
