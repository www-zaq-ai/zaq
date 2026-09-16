# Dev Setup

## Getting Started

```bash
mix setup && mix phx.server   # http://localhost:4000/bo
```

Default credentials on fresh database: `admin` / `admin` (forced password change on first login).

This command runs the development server over HTTP. Docker uses a production
release, with HTTP exceptions only for request hosts `localhost` and `127.0.0.1`.
For LAN or public server deployment, configure `PHX_HOST` and TLS using the
[README production HTTPS guide](../README.md#production-deployment-and-https);
changing the browser URL to a server IP is not sufficient.

---

## Tool Usage

Read and follow [agent tools](agent-tools.md) before tool use: it owns routing,
fallbacks, batching, memory, delegation and Context Mode commands. Do not copy
its procedures here. Serena selects relevant code; Context Mode selects relevant observations.

---

## Running Tests

### Unit Tests
```bash
mix test                  # full suite
mix test test/my_test.exs # single file
mix test --failed         # previously failed tests only
mix q                     # issue quality check
mix precommit             # final gate
```

Follow [the validation lifecycle](WORKFLOW_AGENT.md#phase-4--validate) for timing,
isolated tests, failure handling and final approval; commands here are setup references only.

### E2E Tests (Playwright)

E2E tests run against a dedicated Phoenix server on port `4002` with `MIX_ENV=test E2E=1`.

```bash
cd test/e2e
npm run test              # bootstrap + full suite
npm run test:journeys     # bootstrap + specs only
npm run test:headed       # bootstrap + headed browser (visual debugging)
```

`npm run bootstrap` runs automatically before each test command. It:
- Builds assets for the E2E environment
- Creates and migrates the E2E database
- Seeds it via `test/support/e2e/bootstrap.exs`

#### E2E Spec Coverage

| Spec | What it covers |
|---|---|
| `ingestion.spec.js` | File upload, processing pipeline, job status |
| `system_config.spec.js` | LLM, embedding, SMTP config via BO |
| `knowledge_ops_lead.spec.js` | Knowledge base operations |

#### ProcessorState — Controlled Failure Injection

`Zaq.E2E.ProcessorState` is an OTP Agent that lets tests inject controlled failures
into the ingestion processor. Only available in `MIX_ENV=test` with `E2E=1`.

```elixir
Zaq.E2E.ProcessorState.set_fail(3)  # fail next 3 processing attempts
Zaq.E2E.ProcessorState.reset()      # restore normal behavior
```

Use it in `test/support/e2e/bootstrap.exs` or via the E2E controller from Playwright
`beforeEach` hooks to simulate failure scenarios without touching production code.

#### Prerequisites
- Node.js 20+
- Playwright browsers installed: `cd test/e2e && npx playwright install`

---

## Python Pipeline

Required for PDF/DOCX/XLSX ingestion. `mix setup` fetches Python scripts automatically.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r priv/python/crawler-ingest/requirements.txt
```

To re-fetch or pin Python scripts:
```bash
mix zaq.python.fetch                # latest main
mix zaq.python.fetch --commit <sha> # pin to commit
```

---

## Sub-Agents

Located in `.claude/agents/`. Shared memory at `.swarm/memory.json`.

| Agent | Purpose | When to run |
|---|---|---|
| `project-planner` | Break down tasks and create Beadwork planning issues | Before complex tasks |
| `api-developer` | Build context/domain APIs | New context functions |
| `tdd-specialist` | Write tests first, drive implementation | New features |
| `code-reviewer` | Review PRs for quality and conventions | Before merge |
| `debugger` | Reproduce and fix bugs | Bug reports |
| `refactor` | Clean up and restructure code | Tech debt items |
| `doc-writer` | Write and update documentation | After behavior changes |
| `security-scanner` | Audit for security issues | Before releases |
| `devops-engineer` | CI, deployment, infrastructure | Pipeline changes |
| `product-manager` | Translate requirements into specs | New features |
| `test-runner` | Run test suites and report results | CI validation |
| `doc-gardening` | Scan for stale docs, open fix-up PRs | Weekly / after lib/ changes |
| `node-router-enforcer` | Detect direct module calls bypassing NodeRouter | After BO changes |
| `secret-field-auditor` | Detect unencrypted secret fields | After schema/migration changes |

---

## Docker Storage Defaults

For containerized runs, ZAQ defaults to:

- `STORAGE_VOLUMES=` (one-time import input for Disk data-source volume declarations)
- `STORAGE_VOLUMES_BASE=/zaq/volumes` (base path for imported Disk volume declarations)

When using the default bind mount (`./ingestion-volumes:/zaq/volumes`), ensure the host folder exists:

```bash
mkdir -p ingestion-volumes
```

If using `./zaq-local.sh`, this folder is created automatically.

Disk volumes are configured from Back Office Data Sources > Disk. Each volume path is relative to `Zaq.Storage[:base_path]`.

---

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `ROLES` | `:all` | Services to start on this node |
| `SECRET_KEY_BASE` | — | Phoenix secret key (required in prod) |
| `DATABASE_URL` | — | PostgreSQL + pgvector URL (required in prod) |
| `SYSTEM_CONFIG_ENCRYPTION_KEY` | — | AES-256-GCM key for secret encryption (required) |
| `SYSTEM_CONFIG_ENCRYPTION_KEY_ID` | `v1` | Key ID for rotation tracking |
| `OBAN_INGESTION_CONCURRENCY` | `3` | Parallel document-level ingestion jobs |
| `OBAN_INGESTION_CHUNKS_CONCURRENCY` | `6` | Parallel chunk child-jobs |

Generate an encryption key:

```bash
export SYSTEM_CONFIG_ENCRYPTION_KEY="$(openssl rand -base64 32)"
export SYSTEM_CONFIG_ENCRYPTION_KEY_ID="v1"
```

See `docs/services/system-config.md` for full secret configuration details.
