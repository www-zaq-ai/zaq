# Onboarding (User Portal)

This document describes the first-run admin onboarding flow and the dashboard
portal-activation retry flow. Both paths share the same orchestrator,
`Zaq.UserPortal.Onboarding`, and the same external dependency: the **ZAQ User
Portal** API (provisions a LiteLLM API key for the "ZAQ Router" provider).

## Overview

Onboarding turns a freshly installed ZAQ instance into a usable one by:

1. Forcing the bootstrap admin to set an email + password on first login.
2. Asking for **consent** to provision a ZAQ Portal account (email + machine
   signals are sent to the portal).
3. On acceptance, **provisioning** the "ZAQ Router" credential with the LiteLLM
   API key returned by the portal, and wiring first-run LLM / embedding /
   image-to-text configs.

If consent is declined or the portal is unreachable, the instance is still
fully usable — a keyless "ZAQ Router" credential is scaffolded so the provider
is listed, and the user can retry later from the dashboard banner.

## Modules

| Module | Responsibility |
| ------ | -------------- |
| `Zaq.UserPortal.Onboarding` | Boundary orchestrator: registration write, consent persistence, provisioning sequencing. |
| `Zaq.UserPortal.Provisioner` | Owns the "ZAQ Router" credential — creates/updates it and wires first-run model configs from the portal's LiteLLM key. Delegates persistence to `Zaq.System`. |
| `Zaq.UserPortal.Client` | HTTP client for the portal API (`POST /onboarding`, `PATCH /account/email`, `GET /onboarding/:slug`). |
| `Zaq.UserPortal.ClientBehaviour` | Behaviour resolved via `Application.get_env(:zaq, :user_portal_client, …)`; tests substitute a `Mox` mock. |
| `Zaq.UserPortal.AccountSync` | Best-effort sync of email changes to the portal for `accepted` users only. |
| `Zaq.Accounts` | `complete_registration/2` (email + password write) and `bootstrap_admin_pending_onboarding/0` (detects the pending first-run admin). |
| `Zaq.System.MachineSignals` | Collects non-PII machine signals (machine-id, OS, hardware specs) sent to the portal for account de-duplication. |

UI:

| Module | Responsibility |
| ------ | -------------- |
| `ZaqWeb.Live.BO.System.ChangePasswordLive` | First-run bootstrap onboarding: password change → consent modal → provisioning. |
| `ZaqWeb.Live.BO.PortalConsentLive` | Dashboard retry: live_component mounted in the BO header (`bo_layout.ex`) showing the activation banner/modal for users who declined at bootstrap. |
| `ZaqWeb.Components.PortalConsentModal` | Pure presentational consent modal (email capture, accept/decline). Performs no portal calls. |

## Bootstrap Onboarding Flow (first run)

Entry point: an admin whose account is still in the pending state.

1. **Login** (`LoginLive` / `BOSessionController.bootstrap_login`) detects
   `Accounts.bootstrap_admin_pending_onboarding/0` and routes to
   `/bo/change-password`.
2. **`ChangePasswordLive`** collects email + new password. On submit it fetches
   portal metadata (`fetch_onboarding("free")`):
   - **Plan active & reachable** → show the consent modal.
   - **Unavailable** → skip the modal and onboard with consent `:unavailable`.
3. **Accept** (`accept_portal_consent`) → `complete_bootstrap_onboarding(user,
   attrs, :accepted)`. **Registration is committed first** (`ZAQ-first`), then
   the portal is provisioned — a portal failure never blocks account creation:
   - **Provisioning succeeds** → consent `"accepted"`, credential + model configs
     wired, post-accept modal shown.
   - **Provisioning fails** (unreachable or 5xx) → the account stays registered,
     consent is recorded `"declined"`, the keyless "ZAQ Router" credential is
     scaffolded, and the user is routed to `/bo/dashboard` with an info flash so
     they can retry from the dashboard banner.
   - **Email already on the portal (`409`)** → re-provisioning cannot help, so
     consent is recorded **`"portal_registered"`** (a distinct state that keeps
     the activation banner hidden), the keyless "ZAQ Router" credential is
     scaffolded, and the flash tells the user to fetch their existing key and set
     it on the ZAQ Router credential.
4. **Decline** (`decline_portal_consent`) → consent `:declined`.
5. **`complete_bootstrap_onboarding/3`** writes registration via
   `Accounts.complete_registration/2`, then `apply_consent/2` provisions and
   persists the recorded consent. For declined/unavailable — and for an
   `:accepted` provisioning failure — it scaffolds the keyless "ZAQ Router"
   credential so the provider is listed for the dashboard retry.

### Post-accept

On a successful `:accepted` provisioning, a "you're all set" modal is shown;
`close_post_accept_modal` navigates to `/bo/ingestion`. Declined, unavailable,
and `:accepted`-with-failed-provisioning onboarding redirect to `/bo/dashboard`.

## Dashboard Retry Flow (`activate_portal/2`)

Mounted via `PortalConsentLive` in the BO header for users who didn't accept at
bootstrap. Metadata + reachability are fetched **once** on component mount.

- `accept_portal_consent` → `Onboarding.activate_portal(user, entered_email)`.
- `activate_portal/2` validates the email up front, provisions, and persists the
  email + `"accepted"` consent **only after provisioning succeeds** — a failed
  attempt commits nothing.
- `entered_email` is used when the user has no email on file, or when they supply
  a non-blank override (the 409 email-correction flow).
- Errors are mapped to UI modes: `:allow_override` (email conflict) or
  `:none` (generic).

## Consent States

Persisted on `users.portal_consent`:

| Value | Meaning |
| ----- | ------- |
| `"accepted"` | Provisioned successfully; eligible for `AccountSync` email sync. |
| `"declined"` | User declined, **or** portal was unreachable (`:unavailable`). Dashboard retry banner remains available. Keyless "ZAQ Router" credential scaffolded. |
| `"portal_registered"` | Email already exists on the portal (`409`). Banner **hidden** (re-provisioning can't help); user must paste their existing key into the ZAQ Router credential. Changing email later re-shows the banner (via `refresh_portal_banner_after_email_change/1`) unless the router already has a key. |

## Provisioning Details (`Provisioner`)

- `provision_for_user/1` — calls `client().onboard_user(email)`; on
  `{:ok, %{litellm_api_key: key}}` runs `provision_with_key/2`, which creates/updates
  the "ZAQ Router" credential and wires first-run `LLMConfig`, `EmbeddingConfig`,
  and `ImageToTextConfig`.
- `ensure_offline_credential/0` — creates the "ZAQ Router" credential with **no**
  API key (does not wire model configs, does not overwrite an existing
  credential). A later successful claim updates the same credential by name and
  fills in the key.

## Portal HTTP API (`Client`)

| Call | Endpoint | Payload / Notes |
| ---- | -------- | --------------- |
| `onboard_user/1` | `POST {base}/onboarding` | `{email, machine_signals, plan: "free", network}`. Returns `{:ok, %{litellm_api_key}}` or `{:error, {status, body}}`. |
| `update_email/2` | `PATCH {base}/account/email` | Bearer = LiteLLM API key. Maps 400/401/403/409/422 to atom error codes. |
| `fetch_onboarding/1` | `GET {base}/onboarding/:slug` | Any failure (refused/timeout/non-200/5xx) returns `:unavailable`. |

- Base URL: `Application.fetch_env!(:zaq, :user_portal_base_url)`.
- Client resolution: `Application.get_env(:zaq, :user_portal_client, Zaq.UserPortal.Client)`.
- In e2e, `ZaqWeb.E2EController` provides a loopback portal stub (`/e2e/portal/*`)
  pointed at by `user_portal_base_url` in `config/test.exs`.

## Account Sync

`AccountSync.sync_email/1` pushes email changes to the portal **only** for
`portal_consent: "accepted"` users. Failures are logged but never block the
local DB write — the portal is best-effort.

## Tests

- `test/zaq/user_portal/onboarding_test.exs` — orchestrator unit tests.
- `test/zaq_web/live/bo/system/onboarding_scenarios_test.exs` — bootstrap flow scenarios.
- `test/zaq_web/live/bo/system/onboarding_scenarios_integration_test.exs` — integration scenarios.
- Portal calls are mocked via `Zaq.UserPortal.ClientMock` (`Mox`).
