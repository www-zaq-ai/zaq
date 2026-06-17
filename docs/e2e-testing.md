# E2E Testing Guide

## Overview

E2E tests use [Playwright](https://playwright.dev/) and live in `test/e2e/`. The server runs on port `4002` with `MIX_ENV=test E2E=1`, which enables special `/e2e/*` endpoints for direct DB seeding.

```
test/e2e/
├── playwright.config.js     # Playwright config (port, timeout, browser)
├── support/
│   ├── bo.js                # Shared page helpers — add ALL reusable functions here
│   └── global-setup.js      # One-time startup: asset check + /e2e/health
└── specs/
    ├── agents.spec.js
    ├── ingestion.spec.js
    ├── people.spec.js
    ├── system_config.spec.js
    └── ...
```

---

## Running Tests

### Prerequisites

1. **PostgreSQL** reachable at `localhost:5432` (same as CI and `docker compose` in this repo). With `E2E=1`, the app re-applies DB settings **after** `config/test.secret.exs`, so a worktree-specific repo port in that file does not apply to the E2E server. Override only when intentional: `E2E_DB_HOST`, `E2E_DB_PORT`, `E2E_DB_USER`, `E2E_DB_PASSWORD`.

2. Build assets (first time or after asset changes):
   ```bash
   mix assets.setup && mix assets.build
   ```

3. Install Playwright dependencies (first time):
   ```bash
   cd test/e2e && npm install
   ```

### Run all tests

```bash
cd test/e2e
npx playwright test
```

### Run a single spec (standard)

```bash
cd test/e2e
npx playwright test specs/agents.spec.js
```

### Debug a failing spec

Use `--reporter=line` for compact, readable failure output:

```bash
cd test/e2e
npx playwright test specs/agents.spec.js --reporter=line
```

### Watch with headed browser (slow motion)

```bash
cd test/e2e
SLOW=1 npx playwright test specs/agents.spec.js --reporter=line
```

Set `SLOW=500` (ms) to control the slow-mo delay.

### Run a single test by title

```bash
cd test/e2e
npx playwright test specs/agents.spec.js --reporter=line -g "add tools and MCP endpoint"
```

### CI mode

In CI, the server is always started fresh (`reuseExistingServer: false`). Locally, Playwright reuses an already-running server on port 4002.

---

## How the Server Boots

`playwright.config.js` starts the Phoenix server automatically:

```js
webServer: {
  command: "sh -c 'cd ../.. && PORT=4002 MIX_ENV=test E2E=1 MIX_BUILD_PATH=_build/test-e2e mix phx.server'",
  url: "http://localhost:4002/bo/login",
  reuseExistingServer: !process.env.CI,
}
```

The `E2E=1` flag enables the `/e2e/*` API routes used for DB seeding. Without it, those endpoints return 404 and tests fail.

---

## Test Philosophy: Seed via API, Not via UI

**Each spec tests one page.** It must not navigate to other pages to set up prerequisites.

### Wrong — navigating to System Config to create a credential before testing the Agent page

```js
// DON'T DO THIS
await page.goto("/bo/system-config")
await page.click('[phx-value-tab="ai_credentials"]')
await page.click('[phx-click="new_ai_credential"]')
// ... fill form, save ...
await page.goto("/bo/agents")
// now finally test the agent page
```

This is slow, fragile, and tests the wrong thing. If System Config is broken, the Agent spec fails for unrelated reasons.

### Right — seed the DB directly via the E2E API, then go straight to the page under test

```js
// DO THIS
const req = await apiRequest.newContext()
const credential = await createE2EAiCredential(req, {
  name: `E2E Cred ${Date.now()}`,
  provider: "OpenRouter",
  endpoint: "https://openrouter.ai/api/v1",
  api_key: `e2e-key-${Date.now()}`,
  description: "Seeded for agents spec",
})
await req.dispose()

await loginToBackOffice(page)
// Now test the Agent page directly
```

The `/e2e/*` endpoints insert records directly into the test DB via Ecto — no page navigation, no form fills, no flakiness from unrelated UI.

### Benefits

- **Speed** — seeding via API takes milliseconds vs. seconds of UI interaction
- **Isolation** — a bug in System Config UI does not break the Agent spec
- **Clarity** — each spec tests exactly one page's behaviour
- **Stability** — fewer moving parts = fewer race conditions

---

## DB Seeding API

These functions are in `test/e2e/support/bo.js` and hit the `/e2e/*` endpoints:

| Function | What it does |
|---|---|
| `resetE2EState(request)` | Truncates test tables and resets to baseline. Call in `beforeAll`. |
| `setE2ESystemConfig(request, key, value)` | Sets a system config key directly in DB. |
| `createE2EAiCredential(request, attrs)` | Inserts an AI provider credential. Returns `{ id, name, provider }`. |
| `createE2EConversation(request, attrs)` | Inserts a conversation for the E2E admin user. Body: required `channel_type`; optional `title`, `channel_user_id`, `status` (`active` / `archived`), `user_id`. Returns `{ ok, id, title, channel_type, status }`. |
| `createE2EMcpEndpoint(request, attrs)` | Inserts an MCP endpoint record. Returns the created record. |

### Pattern: `beforeAll` with reset + seed

```js
const { createE2EAiCredential, resetE2EState, loginToBackOffice } = require("../support/bo")

test.describe("Agent page", () => {
  let apiRequest
  let credential

  test.beforeAll(async ({ playwright }) => {
    apiRequest = await playwright.request.newContext()
    await resetE2EState(apiRequest)                    // clean slate
    credential = await createE2EAiCredential(apiRequest, {
      name: "E2E Credential",
      provider: "OpenRouter",
      endpoint: "https://openrouter.ai/api/v1",
      api_key: "e2e-key",
      description: "Seeded",
    })
    await apiRequest.dispose()
  })

  test("creates an agent", async ({ page }) => {
    await loginToBackOffice(page)
    // test the agent page directly
  })
})
```

---

## Shared Helpers: `support/bo.js`

**Any function used across more than one spec must live in `test/e2e/support/bo.js`.**

Do not define helpers inline inside a spec file if they could be reused. Move them to `bo.js` and export them.

### Adding a new helper

1. Write the function in `bo.js`
2. Add it to the `module.exports` block at the bottom of `bo.js`
3. Import it in the spec: `const { myHelper } = require("../support/bo")`

### Current exports

```js
module.exports = {
  loginToBackOffice,
  gotoBackOfficeLive,
  waitForLiveViewConnected,
  waitForLiveViewSettled,
  waitForServerRoundTrip,
  dismissFlash,
  pickSearchableSelect,
  pickFirstSearchableSelectOption,
  createAiCredential,       // UI-based (legacy) — prefer createE2EAiCredential
  resetE2EState,            // POST /e2e/reset
  setE2ESystemConfig,       // POST /e2e/system-config
  createE2EAiCredential,    // POST /e2e/ai-credential
  createE2EConversation,    // POST /e2e/conversations
  createE2EMcpEndpoint,     // POST /e2e/mcp-endpoint
}
```

> `createAiCredential` (no `E2E` prefix) drives the UI form on System Config — it exists for legacy reasons. Prefer `createE2EAiCredential` (API-based) in all new tests.

---

## What Each Spec Tests

| Spec file | Page under test |
|---|---|
| `agents.spec.js` | `/bo/agents` — Agent creation, credential selection, model picker, tools, MCP endpoints |
| `ingestion.spec.js` | `/bo/ingestion` — File ingestion pipeline |
| `people.spec.js` | `/bo/people` — User/team management |
| `system_config.spec.js` | `/bo/system-config` — AI credentials, MCP config, system settings |
| `knowledge_ops_lead.spec.js` | Knowledge operations lead flow |
| `history.spec.js` | `/bo/history` — tabs, filters, bulk selection, conversation table |
| `version_badge.spec.js` | Version badge display |

---

## Flakiness Rules

- **Retries are set to 0.** Do not bump retries to hide a flaky test — fix the race.
- Use `waitForLiveViewSettled(page)` after any Phoenix LiveView event.
- Use `waitForServerRoundTrip(page)` when you need to confirm a phx event was processed.
- Never use hard `page.waitForTimeout(ms)` — use explicit element assertions instead.
- Traces, screenshots, and videos are captured on failure (`retain-on-failure`).

---

## Viewing Failure Artifacts

After a failure, Playwright saves traces in `test/e2e/test-results/`. Open with:

```bash
cd test/e2e
npx playwright show-trace test-results/<test-name>/trace.zip
```
