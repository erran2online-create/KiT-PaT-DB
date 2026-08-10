# n8n on Railway (P12)

## Live instance

- Project: [KiT-PaT](https://railway.com/project/7e675fde-0d77-48d6-9644-2baefc91000a)
- Editor: https://n8n-production-69dd.up.railway.app
- Owner: `erran2online@gmail.com` (password was set during setup — reset via n8n UI if needed)

## Workflows

Imported from this folder:

1. **KiT-PaT Event Reminder 24h** — hourly cron → `n8n_events_due_in_24h` → `reminder_templates` (24h) → `send-telegram` → `n8n_mark_reminder_sent` (once per event via `sent_reminders`)
2. **KiT-PaT Post-Party Recap** — every 30m → `n8n_events_needing_recap` → `generate_party_recap` → `send-telegram`

Telegram digests go to `KITPAT_SUPPORT_CHAT_ID` until `users.telegram_id` / `groups.telegram_group_id` are linked.

## Required Railway env (n8n service)

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `WEBHOOK_URL` / `N8N_WEBHOOK_URL`
- `N8N_ENCRYPTION_KEY` (stable across deploys)
- `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` — required for `$env.*` in HTTP nodes (community plan has no Variables). Without this, nodes fail with "access to env vars denied" / Invalid URL.

## Persistence caveat

SQLite under `/home/node/.n8n` is ephemeral unless a writable volume or Postgres is wired.
Attaching a volume at `/home/node/.n8n` fails with `EACCES` because the official image runs as `node` and cannot `chown` the mount.
Until Postgres (with a real role) or a root-capable entrypoint is fixed, **avoid Railway redeploys** or re-import these workflows after boot.

## Supabase helpers

- RPC `n8n_events_due_in_24h()` — skips events already in `sent_reminders` with `timing=24h`
- RPC `n8n_mark_reminder_sent(p_event_id, p_timing)` — records send (idempotent)
- RPC `n8n_events_needing_recap()`
- Edge `send-telegram` (service_role only) — Bot API style, same secrets as `send-telegram-otp`
