# AGENTS.md

Guidance for AI agents and developers working in the KiT-PaT-DB repository.

## Repository purpose

KiT-PaT-DB is a **documentation / backend source-of-truth** repository for the KiT-PaT party app. It does **not** contain runnable application code, migrations, Edge Function source, or a frontend.

Production backend lives in **Supabase** (Postgres, Auth, Realtime, RLS, RPCs, Edge Functions). The consumer frontend is a **separate repository** (React + Capacitor). Railway (`kitpat-worker-api`, Python/FastAPI) is an optional background-compute layer documented under `backend/railway/`.

## Cursor Cloud specific instructions

### What runs in this repo

There are no long-running services, package managers, or test suites checked into this repository. Development work here is **editing and validating markdown documentation** (war-room specs, frontend contracts, Railway compute notes).

### Linting

Markdown style can be checked with markdownlint (via npx, no install required):

```bash
npx --yes markdownlint-cli "**/*.md"
```

Default rules flag long lines and heading spacing in prose-heavy war-room docs; treat output as advisory unless the team adopts a `.markdownlint.json` config.

### Documentation contract validation

Run the inline validation to confirm war-room specs are internally consistent (required files, Tambola RPC references, D1 migration ledger entries, Railway health contract):

```bash
python3 - <<'PY'
import sys
from pathlib import Path
ROOT, WAR = Path("/workspace"), Path("/workspace/docs/war-room")
RPCS = ["host_create_tambola_session","host_distribute_tambola_tickets","host_start_tambola","host_pause_tambola","host_call_tambola_number","mark_tambola_number","claim_tambola_prize","host_check_tambola_claim"]
lovable = (WAR/"LOVABLE_BUILD_SPEC_V1.md").read_text()
missing = [r for r in RPCS if r not in lovable]
if missing: print("FAIL:", missing); sys.exit(1)
print("OK: all Tambola RPCs documented")
PY
```

### Local doc preview

Serve markdown files over HTTP for quick review:

```bash
python3 -m http.server 8080
```

Then open `http://localhost:8080/docs/war-room/D1_FOUNDATION.md` (raw markdown).

### External services (not in this repo)

End-to-end product testing requires services **outside** this repository:

| Service | Role | Required for E2E |
|---------|------|------------------|
| Supabase | Auth, DB, Realtime, RPCs, Edge Functions | Yes |
| Frontend app (separate repo) | React + Capacitor UI | Yes |
| Cloudinary + `media-signature` Edge Function | Signed media uploads | Yes (media journey) |
| Railway `kitpat-worker-api` | Background timers/artifacts | Optional |
| Razorpay, Sentry, PostHog | Payments, observability | Optional |

### Key documentation paths

- `docs/war-room/D1_FOUNDATION.md` — D1 launch ledger, Tambola variants, remaining work
- `docs/war-room/FRONTEND_CONTRACT.md` — Frontend/Lovable API contract
- `docs/war-room/LOVABLE_BUILD_SPEC_V1.md` — Full reconstruction build spec
- `backend/railway/README.md` — Railway compute layer plan (`GET /health` → `{"status":"ok"}`)

### Git workflow

Standard git workflow applies. No pre-commit hooks or CI are configured in this repository.
