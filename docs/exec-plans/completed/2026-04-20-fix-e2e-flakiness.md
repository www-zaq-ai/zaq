# Execution Plan: Stabilize E2E Playwright Suite

**Date:** 2026-04-20
**Author:** Claude (fix/e2e branch)
**Status:** `active`
**Related debt:** Flaky Playwright E2E runs on `.github/workflows/e2e.yml`
**PR(s):** (to be opened from branch `fix/e2e`)

---

## Goal

Eliminate intermittent failures in the Playwright suite (`test/e2e/specs/`). Today
the same commit can pass or fail between runs with no code change. "Done"
means 10 consecutive green runs on CI for the full suite, retries set to `0`
(not masking flakiness), and removal of every `page.waitForTimeout(...)` sleep
and every point-in-time `isVisible()`/`isChecked()` guard used as a race probe.

---

## Context

Reviewed before planning:
- `test/e2e/playwright.config.js` — `fullyParallel: false`, `workers: 1`,
  `retries` unset (defaults to 0), `reuseExistingServer: !CI`.
- `test/e2e/support/bo.js` — `loginToBackOffice`, `waitForLiveViewConnected`,
  `ensureAssetsAvailable`.
- `test/e2e/specs/ingestion.spec.js`
- `test/e2e/specs/knowledge_ops_lead.spec.js`
- `test/e2e/specs/system_config.spec.js`
- `test/e2e/specs/people.spec.js`
- `test/support/e2e/e2e_controller.ex` — current E2E-only endpoints
  (`/e2e/processor/{fail,reset}`, `/e2e/health`, `/e2e/telemetry/points`,
  `/e2e/logs/recent`).
- `.github/workflows/e2e.yml` — single job, no retries, postgres service.
- `docs/services/ingestion.md`, `docs/services/system-config.md`,
  `docs/conventions.md`.

---

## Root-Cause Inventory

Concrete sources of flakiness found in the current suite. Each step below fixes
at least one of these.

| # | Symptom | Location | Root cause |
|---|---|---|---|
| F1 | Stale-badge test races with mtime granularity | `knowledge_ops_lead.spec.js:170` | `await page.waitForTimeout(5000)` — filesystem mtime is coarse on ext4 and flaky on mounted tmpfs |
| F2 | `openFirstSourcePreviewModal` occasionally times out | `knowledge_ops_lead.spec.js:64` | Source chip rendered asynchronously after Oban answering job; no wait for chat response ready |
| F3 | "Embedding not configured" banner skip is wrong | `ingestion.spec.js:99` | `isVisible({ timeout: 3_000 }).catch(() => false)` — a point-in-time check used as state probe; skips when LiveView just hasn't rendered the banner yet |
| F4 | `selectAndIngest` toggles selection off when row re-renders during job | `ingestion.spec.js:67` | `isChecked()` is point-in-time; between the read and the re-click, PubSub re-renders the checkbox |
| F5 | Flash `"… settings saved."` asserts match the previous test's leftover toast | all specs | Flash stays in DOM 5s; tests do not dismiss/wait for hidden before asserting in the next test |
| F6 | Login helper loops forever when username form renders before LiveView attaches | `support/bo.js:66` | Fill happens before `phx-connected`; form submit becomes a plain POST and redirects differently |
| F7 | Cross-test DB leakage alters dimension/model combinations | system_config tests | No reset of `system_config` between tests; prior model-change persists into next test's form defaults |
| F8 | `waitForEvent("filechooser")` + click race | `ingestion.spec.js:337-340` etc. | Promise attached AFTER click in a couple of places produces intermittent timeout |
| F9 | `expect(row.locator("span", { hasText: "ingested" })).not.toBeVisible()` fires immediately | `ingestion.spec.js:220,284,301` | Default 5s expect timeout but the "ingested" span may still be rendering; non-assertion needs `not.toBeVisible({ timeout: ... })` only after positive anchor |
| F10 | Top_p=0.9 default cannot be saved (real UI bug) | noted in spec | Masked by test workaround; any test that doesn't set it to 0.91 sometimes fails on boundary validation |
| F11 | Chat "baseline response" test races on the previous answer | `knowledge_ops_lead.spec.js:124` | `clear-chat-button` click not awaited to completion before filling input |
| F12 | Playwright `retries` is 0 — a single transient LiveView reconnect fails the suite | `playwright.config.js` | No retry budget even for known-transient network hiccups |
| F13 | `reuseExistingServer: !CI` means local runs carry state across suite invocations | `playwright.config.js` | Local debugging diverges from CI behaviour |
| F14 | Asset check on every login slows cold runs and times out | `support/bo.js:13` | `mix assets.build` races on first run; `page.request.get` fires before webServer is ready |

---

## Approach

Fix in three layers, smallest-blast-radius first:

1. **Test infrastructure (Playwright config + helpers)** — raise the default
   expect timeout, remove `retries: 0` implicit, add a LiveView settle helper
   that waits for `phx-loading` class to clear on the closest component, not
   just `phx-connected` on the root. No product code changes.

2. **Replace wall-clock waits with state-driven waits** — remove every
   `page.waitForTimeout(...)`, replace with an E2E-only endpoint or a
   deterministic UI signal. For the stale-badge case, add
   `POST /e2e/ingestion/touch_file` to `ZaqWeb.E2EController` that bumps the
   source file's mtime server-side (authoritative, no FS granularity issue).

3. **Reset server state between describe blocks** — extend
   `ZaqWeb.E2EController` with `POST /e2e/reset` that truncates `system_config`,
   `ai_credentials`, `ingest_jobs`, and clears `tmp/e2e_documents/`. Call it in
   a suite-level `beforeAll` where each `describe` needs a clean slate. This is
   safe: routes are compiled away outside `MIX_ENV=test` via
   `Application.compile_env(:zaq, :e2e, false)` (see controller line 9).

Alternatives considered and rejected:
- **Enable Playwright `retries: 2`** — would green the board but hide real
  bugs; explicitly rejected by the "done" criterion.
- **`fullyParallel: true`** — tempting, but BO state and PubSub globals make
  this a bigger rewrite; defer.
- **Sandbox DB per test via Ecto sandbox over HTTP** — cleanest long-term, but
  requires carrying the Ecto sandbox token through Playwright request
  headers; larger blast radius than the targeted reset endpoint.

---

## Steps

Each step is independently shippable and green-on-CI before starting the next.

### Step 1 — Tighten the Playwright config and helpers
- [ ] In `test/e2e/playwright.config.js`: raise `expect.timeout` to 20_000
      only for CI via `process.env.CI`, keep local at 15_000. Leave
      `retries: 0` explicit with a comment referencing this plan.
- [ ] In `test/e2e/support/bo.js`:
  - Add `waitForLiveViewSettled(page, locator)` that waits for the nearest
    `[data-phx-component]` ancestor to not carry `phx-change-loading`,
    `phx-click-loading`, or `phx-submit-loading`.
  - Drop `ensureAssetsAvailable` from every login — move to a single
    `globalSetup` hook that runs once per suite.
  - Harden `loginToBackOffice` to await `waitForLiveViewConnected` **before**
    the first `.fill()` call (fixes F6).
  - Bump login retry budget from 2 → 4 with exponential backoff.

### Step 2 — Add `POST /e2e/reset` and per-describe resets
- [ ] Extend `ZaqWeb.E2EController` (`test/support/e2e/e2e_controller.ex`)
      with a `reset_all/2` action that:
  - Truncates `system_configs`, `ai_credentials`, `ingest_jobs`,
    `documents`, `chunks` (if present).
  - Calls `ProcessorState.reset()`.
  - Wipes `tmp/e2e_documents/`.
  - Reseeds the `e2e_admin` user.
- [ ] Wire route in `lib/zaq_web/router.ex` under the existing `:e2e` scope.
- [ ] Call `/e2e/reset` from `beforeAll` in each spec. Do NOT put it in
      `beforeEach` — too slow; scope to describe block.
- [ ] Document in `docs/services/ingestion.md` that a clean DB is assumed.

### Step 3 — Kill every wall-clock wait
- [ ] `knowledge_ops_lead.spec.js:170` — remove `waitForTimeout(5000)`; add
      `POST /e2e/ingestion/touch_file?path=...` that runs
      `File.touch!(path, now + 60)` server-side. Replace the sleep with a
      call + assertion that `fileRow(...)` carries the stale badge.
- [ ] `knowledge_ops_lead.spec.js:124` — after `clear-chat-button` click,
      await `expect(page.locator("#chat-messages")).toBeEmpty()` before fill.
- [ ] Grep all specs for `waitForTimeout` and delete every occurrence, adding
      a matching `expect(...)` state wait.

### Step 4 — Replace point-in-time probes
- [ ] `ingestion.spec.js:99` — replace the conditional skip with a
      `/e2e/reset` call in `beforeAll`, then unconditionally assert the
      banner appears on a fresh DB.
- [ ] `ingestion.spec.js:67` (`selectAndIngest`) — add a `waitForLiveViewSettled`
      call before `isChecked()`, and re-read the checkbox locator after
      settle to avoid a stale handle when the row re-renders.
- [ ] system_config.spec.js:171, 584, 626 — replace
      `(await a.isVisible()) || (await b.isVisible())` with
      `Promise.race([a.waitFor(), b.waitFor()])`.

### Step 5 — Flash-toast isolation
- [ ] Add `dismissFlash(page)` helper that clicks the flash close button and
      awaits `not.toBeVisible()`.
- [ ] Every spec that asserts `"… settings saved."` calls `dismissFlash`
      immediately after, so the next assertion starts from a clean overlay.

### Step 6 — Fix the filechooser race (F8)
- [ ] Refactor all `filechooser` blocks to the documented pattern:
  ```js
  const [chooser] = await Promise.all([
    page.waitForEvent("filechooser"),
    page.locator(SEL.uploadBrowseTrigger).click(),
  ]);
  ```
  The current code attaches the promise before the click but in some tests
  the `await` is on the wrong expression — fix uniformly.

### Step 7 — Fix the `top_p=0.9` product bug (F10)
- [ ] Out of scope here — file issue, link from `docs/exec-plans/tech-debt-tracker.md`.
      Keep the spec workaround for now but add a top-of-file comment pointing
      to the issue.

### Step 8 — CI hardening
- [ ] `.github/workflows/e2e.yml`: upload `test/e2e/playwright-report` on
      failure only (currently `if: always()` — keep) AND surface the Playwright
      HTML report as a GitHub summary step using `dorny/test-reporter`.
- [ ] Add a nightly `workflow_dispatch` job that runs the suite 10×
      back-to-back to catch regressions of this plan.

### Step 9 — Verification
- [ ] Run `npm --prefix test/e2e run test` locally 10× in a loop — all green.
- [ ] Force-push to a throw-away PR and let CI run 5× — all green.
- [ ] Close out plan, move to `docs/exec-plans/completed/`.

---

## Decisions Log

| Decision | Rationale | Date |
|---|---|---|
| Retries stay at 0 | Masking known flakes is the trap we're getting out of | 2026-04-20 |
| Reset scope: describe-level, not test-level | Per-test reset inflates runtime ~3×; describe scope is a good tradeoff given `workers: 1` | 2026-04-20 |
| Add `POST /e2e/reset` over DB sandbox | Smaller change, compiled-away in prod via `@e2e_enabled` guard | 2026-04-20 |
| `top_p=0.9` bug deferred | Product fix, not a test-infra fix; tracked separately | 2026-04-20 |

---

## Blockers

| Blocker | Owner | Status |
|---|---|---|
| Need confirmation that `POST /e2e/reset` is acceptable in the E2E controller scope | Jad | open |

---

## Definition of Done

- [ ] All steps above completed
- [ ] `page.waitForTimeout` count in `test/e2e/specs/**` is 0
- [ ] 10 consecutive green runs on CI with `retries: 0`
- [ ] `mix precommit` passes
- [ ] `docs/services/ingestion.md` notes the `/e2e/reset` contract
- [ ] Plan moved to `docs/exec-plans/completed/`
