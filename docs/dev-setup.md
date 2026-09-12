# Dev Setup

## Getting Started

For the Docker installer or a server deployment, use the [deployment guide](operations/deployment.md). This guide is for developing ZAQ from source.

### Prerequisites

- Elixir and Erlang/OTP: use the versions in [`.tool-versions`](../.tool-versions); the supported Elixir constraint is in [`mix.exs`](../mix.exs).
- PostgreSQL 16+ with [pgvector](https://github.com/pgvector/pgvector) 0.7.0+ (embeddings use `halfvec`).
- Python 3.10+ for the document conversion pipeline.
- Node.js 20+ if running Playwright browser tests.

### Bootstrap and start

Clone the repository:

```bash
git clone https://github.com/www-zaq-ai/zaq.git
cd zaq
```

Before setup, check the PostgreSQL connection in [`config/dev.exs`](../config/dev.exs).
The development database name is derived from your branch. Configure `DB_USER` and
`DB_PASSWORD` with the new owner credentials.

Before running any migrations, have a DBA bootstrap the target database, restricted
credentials and extensions with the [database setup script](database-setup.md).
Repeat for the separately named test and E2E databases before their first migration.
`mix setup`, `mix test` and E2E bootstrap do not install extensions. After dropping
a database, rerun DBA bootstrap before migrating again. Bootstrap refuses any
existing `schema_migrations`, even an empty ledger; use explicit DBA maintenance
for already-migrated databases rather than rerunning bootstrap.

```bash
mix setup && mix phx.server   # http://localhost:4000/bo
```

`mix setup` fetches dependencies, creates/migrates/seeds the database, sets up and builds assets, and fetches the Python scripts. Complete the [Python environment setup](#python-pipeline) before using document conversion. If database setup fails because of connection settings, correct them and rerun `mix setup`.

To start with an interactive Elixir shell instead:

```bash
iex -S mix phx.server
```

Default credentials on fresh database: `admin` / `admin` (forced password change on first login).

Open [Back Office](http://localhost:4000/bo/login), set your email and a new password, then configure AI provider credentials and models in **System Config**. Existing administrator accounts are not overwritten by seeding. See [system configuration](services/system-config.md) for provider settings and credential management.

This command runs the development server over HTTP. Docker uses a production
release, with HTTP exceptions only for request hosts `localhost` and `127.0.0.1`.
For LAN or public server deployment, configure `PHX_HOST` and TLS using the
[production HTTPS guide](operations/deployment.md#production-deployment-and-https);
changing the browser URL to a server IP is not sufficient.

### Local secret encryption

The checked-in development configuration uses a development-only encryption key. Do not use it for a deployed instance or real credentials. To use your own key, add the environment-backed configuration example from [SMTP password encryption](services/system-config.md#smtp-password-encryption) to the untracked `config/dev.secret.exs`, then export:

```bash
export SYSTEM_CONFIG_ENCRYPTION_KEY="$(openssl rand -base64 32)"
export SYSTEM_CONFIG_ENCRYPTION_KEY_ID="v1"
```

Keep the key securely for later sessions rather than regenerating it for an existing database. Exporting a variable alone does not override the checked-in development key. Changing a key without migrating encrypted values makes existing secrets unreadable. The same encryption infrastructure protects other sensitive fields, not only SMTP passwords.

---

## Tool Usage

Automated coding-agent work requires Context Mode, Serena and Beadwork. Follow
[agent workflow setup](agent-setup.md) for official upstream instructions and
new-environment readiness checks.

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

Agent definitions live in `.claude/agents/` and `.opencode/agents/`; availability and
tools depend on the active host, so inspect exposed agents rather than assuming all
names below are callable. Beadwork owns durable plans/progress; repository docs and
supporting memories follow [documentation hygiene](documentation.md).

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

See [persistent storage](operations/deployment.md#persistent-storage) for the Docker bind mount and the separate Back Office Disk volume declaration. Creating a host folder does not automatically expose it as a data source.

Docker Compose automatically provisions a fresh bundled database before starting
ZAQ, using a one-shot invocation of the ZAQ image. Subsequent Compose starts validate
the installation rather than replaying DBA setup. ZAQ uses the existing owner
`DATABASE_URL` environment variable; provisioning uses separate DBA credentials and
the supplied owner/reader passwords. There are no generated credential files or
credential volumes. See [database bootstrap](database-setup.md#docker-image-and-automatic-compose-bootstrap)
for required environment variables, restart behavior and legacy database handling.

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
