# Execution Plan

---

## Plan: Issue 343 - Bootstrap onboarding auto-login and mandatory email on first password change

**Date:** 2026-05-05
**Author:** OpenCode (agent)
**Status:** `completed`
**Related debt:** n/a
**PR(s):** pending
**Issue:** #343

---

## Goal

Implement first-run onboarding behavior so a non-authenticated visitor is automatically logged in as the bootstrap `admin` user only when the instance is in pristine bootstrap state (single user, username `admin`, `inserted_at == updated_at`), then forced through the existing change-password flow. Extend that flow so email becomes mandatory only when missing, validate email format, and persist password+email update before redirecting to dashboard.

---

## Context

What docs were read before writing this plan? What existing code is relevant?

- [x] `docs/architecture.md`
- [x] `docs/conventions.md`
- [x] `docs/services/bo-auth.md`
- [x] Existing code reviewed:
  - `lib/zaq/accounts.ex`
  - `lib/zaq/accounts/user.ex`
  - `lib/zaq_web/live/bo/login_live.ex`
  - `lib/zaq_web/live/bo/login_live.html.heex`
  - `lib/zaq_web/live/bo/system/change_password_live.ex`
  - `lib/zaq_web/live/bo/system/change_password_live.html.heex`
  - `lib/zaq_web/controllers/bo_session_controller.ex`
  - `lib/zaq_web/plugs/auth.ex`
  - `lib/zaq_web/live/bo/auth_hook.ex`
  - `lib/zaq_web/controllers/page_controller.ex`
  - `priv/repo/migrations/20260317091138_seed_default_roles_and_admin_user.exs`
  - `test/zaq_web/live/bo/login_live_test.exs`
  - `test/zaq_web/live/bo/system/change_password_live_test.exs`
  - `test/zaq_web/controllers/bo_session_controller_test.exs`
  - `test/zaq/accounts_test.exs`

### Infrastructure Audit

Confirm before writing any step — what already exists that this plan must use or extend?

- [x] Existing entry points checked (Factory, Executor, builders, helpers): n/a (BO auth/accounts domain, not agent pipeline)
- [x] `@moduledoc` read for every module that will receive new code:
  - `Zaq.Accounts`
  - `Zaq.Accounts.User`
  - `ZaqWeb.Live.BO.LoginLive`
  - `ZaqWeb.Live.BO.System.ChangePasswordLive`
- [x] No parallel code path being created where an existing one can be extended: extend existing login LiveView mount path and existing change-password flow
- [x] Provider/credential/URL logic confirmed to stay in its designated module: n/a

---

## Approach

Keep onboarding logic centralized in `Zaq.Accounts` and reuse existing BO auth/session primitives. `LoginLive` will remain the public entrypoint and will conditionally auto-bootstrap session only when explicit bootstrap conditions match. The change-password page remains the enforcement gate (`must_change_password`) but will accept an additional conditional email field and perform a single transactional user update through Accounts-level changesets, preserving current redirect behavior and avoiding new authentication pathways.

---

## Steps

- [x] Step 1: Add bootstrap-state detection API in Accounts
  - Module placement check: `Zaq.Accounts` owns auth/user lookup rules; `@moduledoc` covers auth and bootstrap behavior.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): add `Zaq.Accounts` tests for bootstrap detector returning user vs nil.
    - [ ] Branch/path coverage:
      - single user named `admin` with equal timestamps -> match
      - single user not `admin` -> no match
      - multiple users -> no match
      - timestamp mismatch -> no match
    - [ ] Permission/security paths (if applicable): not applicable (no permission bypass changes)
    - [ ] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%`

- [x] Step 2: Auto-login bootstrap admin from BO login page
  - Module placement check: `ZaqWeb.Live.BO.LoginLive` owns login-screen mount and redirect behavior; `@moduledoc` responsibility is consistent.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): extend `login_live_test` to assert no-session bootstrap state redirects to `/bo/change-password` without showing form.
    - [ ] Branch/path coverage:
      - no session + bootstrap state -> auto-login + redirect
      - no session + non-bootstrap -> login form rendered
      - existing session -> existing redirect behavior unchanged
    - [ ] Permission/security paths (if applicable): verify bootstrap auto-login does not trigger when DB state is not pristine
    - [ ] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%`

- [x] Step 3: Extend change-password flow with conditional mandatory email
  - Module placement check:
    - `ZaqWeb.Live.BO.System.ChangePasswordLive` owns form state and submit flow
    - `Zaq.Accounts` + `Zaq.Accounts.User` own validation/persistence rules
    - `@moduledoc` coverage is appropriate for each
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): extend `change_password_live_test` for email-required branch and successful password+email save.
    - [ ] Branch/path coverage:
      - user missing email -> email field displayed and required
      - missing/invalid email -> changeset error rendered
      - valid email + valid password -> DB updates both, redirects dashboard
      - user already has email -> email field omitted and password-only path still works
      - password mismatch still fails before persistence
    - [ ] Permission/security paths (if applicable): ensure only session user is mutated (existing flow constraint retained)
    - [ ] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%`

- [ ] Step 4: Documentation and regression alignment for issue #343
  - Module placement check: docs under `docs/services/bo-auth.md` own BO auth behavior description.
  - Temporary code? no
  - Tests to add before implementation:
    - [ ] Integration test(s): none (doc step)
    - [ ] Branch/path coverage: n/a
    - [ ] Permission/security paths (if applicable): n/a
    - [ ] Edge external API mocks only: none
  - Coverage target for files touched in this step: `>= 95%` for code files, n/a for docs-only files

---

## Decisions Log

Record decisions made during implementation. Future agents need this context.

| Decision | Rationale | Date |
| -------- | --------- | ---- |
| Detect bootstrap auto-login using strict DB state checks (`count==1`, `username==admin`, `inserted_at==updated_at`) | Avoid accidental privilege escalation and keep behavior limited to pristine first-run systems | 2026-05-05 |
| Keep auto-login in `LoginLive` and not in global auth plug | Limits impact to explicit BO entrypoint and avoids hidden behavior on every protected route | 2026-05-05 |
| Extend existing change-password flow instead of adding new onboarding page | Reuses current enforced path and minimizes UI/permission surface | 2026-05-05 |
| Route bootstrap auto-login through `GET /bo/bootstrap-login` controller action | LiveView cannot write session directly; controller sets `:user_id` then redirects to enforced change-password flow | 2026-05-05 |

---

## Blockers

List anything blocking progress and who/what can unblock it.

| Blocker | Owner | Status |
| ------- | ----- | ------ |
| None | n/a | open |

---

## Definition of Done

- [ ] All steps above completed
- [ ] Tests written and passing
- [ ] Integration tests cover key branches/paths
- [ ] Any mocks are limited to edge external API calls
- [ ] Coverage for every added/modified file is `>= 95%`
- [ ] `mix precommit` passes
- [ ] Relevant docs updated
- [ ] `docs/QUALITY_SCORE.md` updated if domain grade changed
- [ ] Item removed from `docs/exec-plans/tech-debt-tracker.md` if applicable
- [ ] Plan moved to `docs/exec-plans/completed/`
