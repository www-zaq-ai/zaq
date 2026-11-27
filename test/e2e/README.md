# ZAQ E2E (Playwright)

This suite covers synthetic-user journeys for UI regression protection. The journeys are
ExUnit tests on playwright_ex in `test/e2e_pw/`; this directory keeps the JS parts (the
Storybook project, the `support/*.cjs` runners and `support/bo.js` used by the `:real_browser`
tests, and the `node --test` units in `support/*.test.cjs`). See `docs/e2e-testing.md`.

## Scope

- Persona: `Knowledge Ops Lead`
- Test: `test/e2e_pw/knowledge_ops_lead_test.exs`
- Environment: `MIX_ENV=test` with `E2E=1` (uses isolated DB `zaq_test_e2e`)

## Shared BO Helper

Use `Zaq.E2EPw.BO` (`test/support/e2e_pw/bo.ex`) in BO journeys to keep setup consistent
across modules. With the global setup (`test/support/e2e_pw/global_setup.ex`) it:

- checks required frontend assets are served (`/assets/js/app.js`, `/assets/css/app.css`)
- logs into BO with the E2E admin user
- waits for LiveView to be connected before interacting with the UI

This prevents false failures where selectors never appear because LiveView JS was not connected.

## Local Run

```bash
mix playwright.install chromium
mix e2e
```

`npm --prefix test/e2e install` is only needed for the JS parts above.

## What Bootstrap Does

`mix e2e` runs a bootstrap step that:

- migrates the isolated E2E test database (`zaq_test_e2e`)
- creates an E2E admin user (`e2e_admin` / `StrongPass1!` by default)
- resets `tmp/e2e_documents`
- seeds prompt templates required by journeys
- pre-indexes source files through the E2E fake document processor

## CI

The workflow `.github/workflows/e2e.yml` runs this suite on non-release branches (it skips `main`, `release`, and `release/**`).
