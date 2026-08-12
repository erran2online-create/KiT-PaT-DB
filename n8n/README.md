# n8n on Railway (P12 / P15)

## Live instance

- Project: [KiT-PaT](https://railway.com/project/7e675fde-0d77-48d6-9644-2baefc91000a)
- Editor: https://n8n-production-69dd.up.railway.app

## Diagnosis — repeated 24h reminders (P12.2 / P15)

`sent_reminders` + `n8n_events_due_in_24h` were correct in Postgres, and the
**draft/published workflow JSON** included `Mark reminder sent`. But after
`n8n import` / `publish`, the running process was **not restarted**, so the
hourly cron kept the **old no-mark workflow** (n8n warns: “Changes will not
take effect if n8n is running”). That re-sent every hour while the party
stayed in the 24h window. Always restart/redeploy n8n after publishing.

## Workflows

1. **KiT-PaT User Reminder Digest** (P15) — hourly → `get_users_due_for_reminder`
   → Telegram → `n8n_mark_user_reminder_sent`. Respects per-user frequency
   (`once_daily` / `twice_daily` / `thrice_daily` / `hourly`) and active
   window (default 06:00–21:00 local).
2. Legacy **Event Reminder 24h** / **Post-Party Recap** — recap still useful;
   deactivate the old 24h event workflow once the user digest is live.

## Required Railway env (n8n service)

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `WEBHOOK_URL` / `N8N_WEBHOOK_URL`
- `N8N_ENCRYPTION_KEY` (stable across deploys)
- `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` — required for `$env.*` in HTTP nodes

## Persistence caveat

SQLite under `/home/node/.n8n` is ephemeral unless a writable volume or
Postgres is wired. After any redeploy: re-import workflows, publish, **and
restart** the n8n service.

## Supabase helpers

- `user_reminder_preferences` / `user_reminder_sends`
- `get_users_due_for_reminder(p_now)` — optional `p_now` for tests
- `n8n_mark_user_reminder_sent(user_id, slot_index, p_now)`
- Legacy: `n8n_events_due_in_24h`, `n8n_mark_reminder_sent`, `n8n_events_needing_recap`
- Edge `send-telegram` (service_role only)
