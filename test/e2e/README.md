# ZAQ E2E (Playwright)

This suite covers synthetic-user journeys for UI regression protection.

## Scope

- Persona: `Knowledge Ops Lead`
- Spec: `test/e2e/specs/knowledge_ops_lead.spec.js`
- Environment: `MIX_ENV=test` with `E2E=1` (uses isolated DB `zaq_test_e2e`)

## Shared BO Helper

Use `test/e2e/support/bo.js` in BO journeys to keep setup consistent across specs:

- checks required frontend assets are served (`/assets/js/app.js`, `/assets/css/app.css`)
- logs into BO with the E2E admin user
- waits for LiveView to be connected before interacting with the UI

This prevents false failures where selectors never appear because LiveView JS was not connected.

## Local Run

```bash
npm --prefix test/e2e install
npx --prefix test/e2e playwright install chromium
npm --prefix test/e2e run test:journeys
```

## What Bootstrap Does

`npm --prefix test/e2e run test` runs a bootstrap step that:

- migrates the isolated E2E test database (`zaq_test_e2e`)
- creates an E2E admin user (`e2e_admin` / `StrongPass1!` by default)
- resets `tmp/e2e_documents`
- seeds prompt templates required by journeys
- pre-indexes source files through the E2E fake document processor

## CI

The workflow `.github/workflows/e2e-dev.yml` runs this suite on all branches except `main` and release branches.
