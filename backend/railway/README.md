# Railway Compute Layer

Railway is the optional persistent-compute/background-worker layer. Supabase remains the system of record.

Initial responsibilities:
- automatic game timers/workers where an always-on process is preferable to client timers;
- memory/share artifact generation jobs;
- media post-processing orchestration;
- scheduled/background integration work that should not block the app request path.

Do **not** duplicate Postgres/Auth/Realtime here.

## Planned service
`kitpat-worker-api` (Python/FastAPI when Railway workspace is ready)

Health contract: `GET /health` → `{ "status": "ok" }`

Environment will be configured through Railway secrets; no credentials belong in Git.
