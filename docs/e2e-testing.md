# E2E Testing Guide

## Overview

E2E tests use [Playwright](https://playwright.dev/) and live in `test/e2e/`. The server runs on port `4002` with `MIX_ENV=test E2E=1`, which enables special `/e2e/*` endpoints for direct DB seeding.

For **when to author tests**, follow the authoritative
[feature E2E approval gate](testing-approach.md#feature-e2e-approval-gate): track
and update one Beadwork E2E issue during iterations, but implement consolidated
feature coverage only after implementation and explicit human UX/UI approval.
Running existing tests continues as required. Minimal repairs to existing tests
must preserve assertions and intent, never weaken them to hide regressions.

The separate [real browser-tool integration](#real-browser-tool-integration-flow-3)
uses ExUnit and the production `agent-browser` CLI, not the Playwright journey suite.

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

## Real browser-tool integration (Flow 3)

`test/zaq/agent/browser_flow_integration_test.exs` is tagged `:real_browser` and
excluded from normal test runs. Explicitly enabled runs **fail**, rather than
silently skip, when the pinned CLI or a usable Chromium is unavailable.

Prerequisites:
- Normal Mix test dependencies and PostgreSQL, using `config/test.exs` sandbox settings.
- `agent-browser` matching `priv/browser/agent-browser.version` (the same file
  Docker verifies after its Cargo install). Set `AGENT_BROWSER_BIN` to that executable
  when it is not the default on PATH. A global older CLI need not be replaced.
- For the Cargo-only installation, set `AGENT_BROWSER_NATIVE=1` to select the
  intended self-contained Rust/CDP backend explicitly. Do not infer the installed
  binary's default backend from the upstream source tag: CI reached URL validation
  with both `AGENT_BROWSER_NATIVE=0` and `1`. The previous missing-Node-daemon
  explanation was not established. A successful `--version` check does not verify
  browser launch.
- Chromium/Chrome executable; set `AGENT_BROWSER_EXECUTABLE_PATH` to its absolute
  path. The Docker runtime uses `/usr/bin/chromium`, `fonts-liberation`, writable
  `/app` as HOME, and `--no-sandbox,--disable-dev-shm-usage` container flags.

```sh
AGENT_BROWSER_BIN=/absolute/path/to/agent-browser \
AGENT_BROWSER_NATIVE=1 \
AGENT_BROWSER_EXECUTABLE_PATH=/absolute/path/to/chromium \
mix test test/zaq/agent/browser_flow_integration_test.exs --include real_browser
```

Do not set `E2E=1`; no Phoenix server, frontend build, Node, or Playwright package
is needed for this test. It starts its own loopback HTML site and mocked LLM,
then calls the real configured agent and `web_browsing` tool for every command.
The test checks presentation text, navigation URL, form input via a live preview,
the exact POST nonce/value, and a confirmation page. After the first successful
navigation, it also calls the real browsing tool against `localhost` on the same
fixture port while only `127.0.0.1` is allowed. It requires an explicit policy
denial and no new fixture request, then completes the flow in the same session.
Each incoming message waits
for Jido's actual terminal state before the next one. Selector waits replace
timed sleeps. A unique browser session is closed on success and again during
cleanup so failed assertions do not leave that session running.

### GitHub CI

Manually dispatch **Browser Tool Integration** (`.github/workflows/browser-tool.yml`).
It builds Docker's `browser-runtime` target, starts it non-root with host networking,
and runs Mix on the Ubuntu runner against the PostgreSQL service. Host networking
lets container Chromium reach the ephemeral site on runner loopback. This job is
separate from the existing three-browser Playwright matrix and is not required by
normal test runs. A new dispatch-only workflow becomes discoverable in GitHub's
Actions UI once it exists on the default branch.

`test/support/bin/agent-browser-container` forwards argv with `docker exec` to
the **real** CLI in that container. It is not a fake executable and does not
fabricate tool output. The production `app` image inherits the same browser
runtime stage, including the CLI, Chromium, native backend selection, libraries,
fonts and launch flags. The workflow logs the CLI version, Chromium version and
local image ID, then runs `sh test/support/bin/browser-runtime-smoke` to check
**raw Chromium only**, using `--dump-dom about:blank` and an isolated temporary
profile. Each command has a 20-second deadline plus a 5-second kill grace inside
the container; the workflow also bounds the whole step. The profile is cleaned up
on success or failure. Its stdout/stderr is retained as a seven-day artifact.

All CLI navigation uses the existing Bandit `BrowserFlowSite` in the integration
test. There is no extra server, CLI probe session or warm-up navigation. The first
`Executor` request opens its `http://127.0.0.1:<port>` URL with the domain allowlist
unchanged. Do not navigate the CLI to `about:blank`: its missing hostname is
rejected by allowlist validation, even though raw Chromium can render it.

If the first open or its assertions fail, the original assertion is re-raised with
whether the test observed the fixture's `GET /` notification. This is an observation
at failure time, not proof that no request can arrive later. In container runs the
failure also includes bounded `docker inspect` and process-name output **before**
the existing session cleanup. No additional browser command is issued. The normal
page-content, URL, and form assertions remain the acceptance checks.

An
`always()` cleanup step attempts to remove the container and its daemon sessions
after success or failure, and reports removal failures; forced runner termination
can prevent cleanup. The final diagnostics step reports container state and process
names, not full argv/environment or daemon log files. Raw smoke output is from a
trusted blank page only; first-open diagnostics appear in the Mix test failure.
Ordinary tool timeouts still report a generic error to the LLM.

The CLI is built with Cargo `--locked` from the immutable upstream commit in
`priv/browser/agent-browser.revision`; the build verifies its reported version
against `priv/browser/agent-browser.version`. Both production and CI inherit this
same build. The current pin is v0.22.0, commit
`ce1f1f5f8123b97f16aa08e9375659fcdf9c47ab`.

The published crates.io 0.19.0 package processes `Fetch.requestPaused` only at
command boundaries: allowlisted navigation can wait for a paused request that
cannot be resumed while the navigation command is running. The pinned source
starts a background Fetch handler before installing interception. v0.22.0 was
not available through crates.io when this pin was selected, so changing only
the version argument of the old registry install would fail. Do not remove
the allowlist or raise timeouts to work around this dependency defect.

To install the same source locally without replacing a global CLI:

```sh
cargo install agent-browser --git https://github.com/vercel-labs/agent-browser.git \
  --rev "$(cat priv/browser/agent-browser.revision)" --locked --root /your/isolated/install
```

Use that install's `bin/agent-browser` as `AGENT_BROWSER_BIN`. Chromium
and the Debian base currently follow their existing rolling package/image tags;
they are **not** exact-version/digest pinned. Sharing the stage prevents divergent
installation logic, not package drift across builds on different dates. Review
the logged versions when comparing runs; pinning Debian snapshots/digests would
be a separate update/security-maintenance decision.

The browser runs with its container sandbox relaxed, as in production. Tests
restrict allowed domains to `127.0.0.1` and use only trusted local fixtures;
do not repurpose this job for browsing untrusted websites. No repository secrets
or host browser profiles are mounted into the browser container.

## Running Tests

### People authentication journey (isolated, no reset)

After `mix assets.build` and installing `test/e2e` Playwright dependencies plus
Chromium, Firefox and WebKit (`npm exec --prefix test/e2e -- playwright install chromium firefox webkit`):

```sh
mix test test/zaq_web/people_browser_test.exs --include real_browser --timeout 180000
```

This test starts an ephemeral Bandit HTTP server against the existing Phoenix
Endpoint inside SQL Sandbox. The real browser uses regular CSRF forms and
LiveView connections. Only the notification transport is mocked; delivered codes
reach the test browser over its private process stdin, with no test-only public
endpoint. No database reset, E2E bootstrap, external delivery, or Agent/LLM call
is used. The fixture rolls back on completion.

Each of the three engines runs the entire journey at 390px and 1280px. Fixtures
use separate Person identities per engine/viewport and sandbox-scoped send limits.
The journey covers mobile/desktop presentation, email request, incorrect-code
recovery, timestamp countdown/expiry, resend, code formatting, profile entry,
HttpOnly/Lax browser-session cookies, logout and protected-route denial. BO-first
and People-first login, People logout preserving BO, and BO logout preserving
People run in every engine. The supporting browser runner is
`test/e2e/support/people-auth-browser.cjs`, using the shared BO connection/settling
helpers. Countdown testing controls browser wall time without advancing socket
heartbeat timers. A private stdout/stdin checkpoint asks the sandbox owner to age
only the issued challenge's `inserted_at` by 60 seconds before the real resend POST;
its server expiry stays valid. After issuance, browser time aligns to the new
signed deadline. No minute-long sleeps or production clock hooks are used. The
journey also checks row widths, reload persistence and submission/timer races.
This uses Playwright, not the agent-browser CLI from the separate test above.

The same journey checks an access-only profile, enables the fourth **Edit profile**
matrix row through BO and verifies persistence, saves full name and channel priority,
reloads the sorted channels, then revokes edit in a second BO tab while the profile
is mounted. The next save is denied and becomes read-only. Each engine captures
`test/e2e/test-results/people-profile-<engine>-<width>.png`; viewport overflow is
checked at both widths. Name and channel forms save separately. No database reset
or production test hook is used.

### Distributed confidentiality and cookie/logging regression tests

```sh
MIX_ENV=test mix deps.compile phoenix_live_view --force
mix test test/zaq/confidential_event_peer_test.exs test/zaq_web/production_session_options_test.exs test/zaq_web/controllers/person_session_controller_test.exs
```

The peer test requires Erlang `epmd`/`:peer` and the normal isolated test database.
It uses two actual BEAM nodes, real NodeRouter RPC verification/revocation and
PubSub subscribers on both peers. Public controls from each side prove observer
delivery; confidential envelopes remain absent. Authentication credentials stay
inside the peers; only boolean summaries return. Remote database writes roll back
when the peer-owned SQL Sandbox exits. No test database reset is performed.

The production-options test evaluates the endpoint's real session options against
`Config.Reader` production settings without changing application environment.
HTTP/LiveView log tests capture actual pipeline debug output, including a visible
control parameter, and reject submitted OTP/bearer leakage. They do not prohibit
the accepted V1 notification-body persistence.

For the broader People/BO authentication, event routing and notification coverage
gate (including all browser engines and the real peer tests):

```sh
MIX_ENV=test mix coveralls.json \
  test/zaq/accounts test/zaq/accounts_test.exs \
  test/zaq/{node_router,event,event_hop,confidential_event,confidential_event_peer}_test.exs \
  test/zaq/events test/zaq/people/auth_rate_limiter{,_peer}_test.exs \
  test/zaq/channels/people_auth{,_rate_limiter}_test.exs \
  test/zaq/engine/{api,people_auth_gateway,people_access_config_api}_test.exs \
  test/zaq/engine/notifications \
  test/zaq_web/controllers/{bo_session,person_session}_controller_test.exs \
  test/zaq_web/plugs test/zaq_web/live/bo/{auth_hook,login_live}_test.exs \
  test/zaq_web/{router,production_session_options,people_browser}_test.exs \
  --include real_browser --timeout 180000
```

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
await loginToBackOffice(page)
const credential = await createE2EAiCredential(page, {
  name: `E2E Cred ${Date.now()}`,
  provider: "OpenRouter",
  endpoint: "https://openrouter.ai/api/v1",
  api_key: `e2e-key-${Date.now()}`,
  description: "Seeded for agents spec",
})
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
| `createE2EAiCredential(page, attrs)` | Inserts an AI provider credential through the authenticated BO session. Returns `{ id, name, provider }`. |
| `createE2EConversation(request, attrs)` | Inserts a conversation for the E2E admin user. Body: required `channel_type`; optional `title`, `channel_user_id`, `status` (`active` / `archived`), `user_id`. Returns `{ ok, id, title, channel_type, status }`. |
| `createE2EMcpEndpoint(request, attrs)` | Inserts an MCP endpoint record. Returns the created record. |

`loginToBackOffice` uses the authenticated browser state created in global setup.
`createE2EAiCredential` must receive a logged-in page; it reads the CSRF token from
that page and posts with `page.request` so the token and BO session cookie stay in
the same browser context. See [Logging In](#logging-in).

### Pattern: reset in `beforeAll`, log in, then seed once

```js
const { createE2EAiCredential, resetE2EState, loginToBackOffice } = require("../support/bo")

test.describe("Agent page", () => {
  let credential

  test.beforeAll(async ({ playwright }) => {
    const request = await playwright.request.newContext()
    await resetE2EState(request)                    // clean slate
    await request.dispose()
  })

  test.beforeEach(async ({ page }) => {
    await loginToBackOffice(page)

    credential ||= await createE2EAiCredential(page, {
      name: "E2E Credential",
      provider: "OpenRouter",
      endpoint: "https://openrouter.ai/api/v1",
      api_key: "e2e-key",
      description: "Seeded",
    })
  })

  test("creates an agent", async ({ page }) => {
    // test the agent page directly
  })
})
```

---

## Logging In

Global setup signs in once through the regular BO login form, saves the resulting
Phoenix session cookie to Playwright storage state at
`test/e2e/.auth/bo-admin.json`. Journey projects load that state for every page,
so `loginToBackOffice(page)` normally just navigates to the target BO route.
Authenticated E2E setup requests should use `page.request` after `loginToBackOffice`
so they reuse that page's current session cookie and CSRF token without repeating
the login flow.

```js
await loginToBackOffice(page)                              // cached regular-login session
await loginToBackOffice(page, { returnTo: "/bo/people" })  // land straight on the page
```

If a destructive flow invalidates the cached session, `loginToBackOffice` falls
back to the regular login form for the default E2E admin and refreshes the saved
storage state.

The real login form is used when you pass a `password` — **passing one means you
want it verified** — or set `realLogin: true` explicitly:

```js
// onboarding.spec.js — the login journey IS the subject here
await loginToBackOffice(page, { username: user.username, password: user.password })
```

Do not remove the explicit form path from those specs: password verification and
the `must_change_password` redirect are part of what they cover.

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
