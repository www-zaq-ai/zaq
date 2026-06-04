# PR #443 Reviewer Fixes — Implementation Plan

**Branch:** `fix/onboarding-path`  
**Reviewer:** jfayad  
**Last updated:** 2026-06-04

---

## Validity Assessment

| Comment | File | Current? | Valid? | Verdict |
|---|---|---|---|---|
| "all this logic does NOT belong here" | `accounts.ex:194` | Yes | Yes | **Fix — Step 1** |
| "should be removed from here" | `change_password_live.ex:17` | Yes | Yes | **Fix — Step 2** |
| "stop leaking portal concerns… email regression" | `change_password_live.ex:71` | Yes | Yes | **Fix — Step 2** |
| "does not belong here" | `change_password_live.ex:111` | Yes | Yes | **Fix — Step 2** |
| "why loading them and pass them back" | `change_password_live.html.heex:271` | Yes | Yes | **Fix — Step 3** |
| "unnecessary liveness check" | `user_portal/client.ex:31` | Yes | Yes | **Fix — Step 4** |
| "unnecessary if overcomplication" | `config/runtime.exs:25` | Yes | Yes | **Fix — Step 5** |
| "dedicated module for custom provider" | `system.ex` | Resolved | N/A | Already done |
| "no hardcoded offer mention" | `change_password.html.heex` | Outdated | No | Addressed — modal uses dynamic metadata |
| "by default point to live url in runtime" | `runtime.exs` | Outdated | No | Addressed — prod has `"https://portal.zaq.ai"` default |
| "?" and "move to dedicated module" | `dashboard_live.ex` | Outdated | No | Addressed — extracted to `PortalConsentLive` |
| "these too don't belong here" | `dashboard_live.html.heex` | Outdated | No | Addressed — replaced by `<.live_component>` |
| "this is not a machine fingerprint" | `machine_fingerprint.ex` | Outdated | Unclear | Ask reviewer to re-comment on current code |
| "this should be dropped" | `retrieval.ex` | Outdated | No | Code changed; current file is clean |

---

## Step 1 — Move portal provisioning out of `Accounts`

**Reviewer comment:** `accounts.ex:194` — "all this logic does NOT belong here... move to one of the dedicated user portal module"

**What's there now:**  
`Zaq.Accounts` contains `provision_portal_for_user/1` (public) and `attempt_portal_provisioning/1` (private) — both call `UserPortalClient.onboard_user` then `Provisioner.provision_with_key`. These are pure portal concerns living in the wrong context.

**Fix:**  
Move both functions to `lib/zaq/user_portal/provisioner.ex` (`Zaq.UserPortal.Provisioner`), which already exists and is the correct home.

- Add `provision_for_user/1` (public, replaces `provision_portal_for_user/1`) to `Zaq.UserPortal.Provisioner`
- Add `attempt_provision_for_user/1` (public, replaces `attempt_portal_provisioning/1`)
- Update callers in `accounts.ex` to delegate: `Zaq.UserPortal.Provisioner.provision_for_user(user)` etc.
- Remove the portal provisioning function bodies from `accounts.ex`

---

## Step 2 — Remove portal concerns from `ChangePasswordLive` + fix email regression

**Reviewer comments:**
- `change_password_live.ex:17` — "should be removed from here" (the `PortalClient` alias)
- `change_password_live.ex:71` — "stop leaking portal concerns all over the place... email is NOT optional anymore and you introduced a regression"
- `change_password_live.ex:111` — "does not belong here" (`do_complete_onboarding`)

**What's there now:**

```elixir
# line 5
alias Zaq.UserPortal.Client, as: PortalClient

# mount/3 (lines 13–17): LiveView calls PortalClient directly
{portal_reachable, portal_metadata} =
  case PortalClient.fetch_onboarding("free") do ...

# handle_event "change_password" (lines 64–69): email made optional — regression
attrs =
  if is_binary(email) do
    %{"password" => password, "email" => email}
  else
    %{"password" => password}   # ← email silently dropped
  end

# do_complete_onboarding/2 (line 93+): portal orchestration in wrong module
```

**Fix:**

**a) Remove `PortalClient` from `ChangePasswordLive`**  
Delete the `alias Zaq.UserPortal.Client, as: PortalClient` and remove the `fetch_onboarding` call from `mount/3`. The LiveView should not call portal HTTP logic directly. The consent UI is moving to a self-contained component (Step 3).

Remove from `mount/3`:
- `PortalClient.fetch_onboarding("free")` call
- `portal_reachable` assign
- `portal_metadata` assign

**b) Fix the email regression**  
The `change_password` event conditionally drops email when it's `nil`. Email is required on this screen. Fix:

```elixir
# Before
attrs =
  if is_binary(email) do
    %{"password" => password, "email" => email}
  else
    %{"password" => password}
  end

# After
attrs = %{"password" => password, "email" => email}
```

> **Note — dashboard "no email" flow is a separate path and unaffected.**  
> Users who reach the dashboard without an email (e.g. they skipped onboarding) see a
> banner message; clicking it opens the consent modal inside `PortalConsentLive`, which
> has its own email input and handles the provisioning entirely within that component.
> That flow never goes through `ChangePasswordLive`.  
> On the change password screen the email field is **always rendered** (pre-filled with
> `user.email || ""`), so `Map.get(params, "email")` always returns a string. The
> `is_binary` guard is always `true` and the `else` branch that silently drops email is
> unreachable — making it conditional is the regression. The fix above is safe for all
> users including bootstrap admins who have not yet set an email.

**c) Remove `do_complete_onboarding/2`**  
This private function orchestrates portal consent + password change. It will be moved to the consent LiveComponent (Step 3) which will call `Accounts.complete_bootstrap_onboarding/3` directly. Inline the remaining socket plumbing into the LiveView's event handlers or delete it once the component owns the flow.

---

## Step 3 — Decouple `PortalConsentModal` — let it load its own data

**Reviewer comment:** `change_password_live.html.heex:271` — "why loading them and pass them back to this component? Why not simply loading them there? only pass the 'free' param and stop tightly coupling this component to the portal one"

**What's there now:**  
`ChangePasswordLive` fetches portal metadata in `mount/3` and passes every field down to the modal:

```heex
<ZaqWeb.Components.PortalConsentModal.portal_consent_modal
  :if={@portal_reachable}
  show={@show_consent_modal}
  title={@portal_metadata["metadata"]["title"]}
  body={@portal_metadata["metadata"]["body"]}
  accept_label={@portal_metadata["metadata"]["accept_label"]}
  ...
/>
```

**Fix:**  
Convert (or wrap) `PortalConsentModal` so it loads its own metadata internally. The parent should pass only the slug (`"free"`) and callbacks (`on_accept`, `on_decline`):

```heex
<ZaqWeb.Components.PortalConsentModal.portal_consent_modal
  :if={@show_consent_modal}
  slug="free"
  on_accept="accept_portal_consent"
  on_decline="decline_portal_consent"
/>
```

Inside the component, call `PortalClient.fetch_onboarding(slug)` to load title, body, labels — catching any `:unavailable` result. This mirrors the pattern used in `PortalConsentLive` on the dashboard.

---

## Step 4 — Remove liveness pre-check from `UserPortal.Client`

**Reviewer comment:** `user_portal/client.ex:31` — "unnecessary.. directly get the data you need and wrap that call with a case to handle any connectivity error (it will be the same connectivity error for a liveness check or an actual data loading)"

**What's there now:**

```elixir
def fetch_onboarding(slug) do
  case check_liveness() do        # ← extra HTTP round-trip to /health/liveliness
    :reachable -> fetch_onboarding_metadata(slug)
    :unreachable -> :unavailable
  end
end

defp check_liveness do
  # GET /health/liveliness — redundant
end
```

**Fix:**  
Delete `check_liveness/0` entirely. `fetch_onboarding/1` calls `fetch_onboarding_metadata/1` directly. Any connectivity failure (refused, timeout, non-200) already returns `:unavailable` from `fetch_onboarding_metadata`'s error clause — no separate liveness hit needed.

```elixir
def fetch_onboarding(slug) do
  fetch_onboarding_metadata(slug)
end
```

Or inline entirely if `fetch_onboarding_metadata` becomes the only private function.

---

## Step 5 — Simplify `config/runtime.exs` non-prod URL config

**Reviewer comment:** `config/runtime.exs:25` — "what's the purpose of this if? looks like unnecessary overcomplication..."

**What's there now:**

```elixir
if config_env() == :prod do
  config :zaq,
    user_portal_base_url: System.get_env("USER_PORTAL_BASE_URL", "https://portal.zaq.ai"),
    litellm_base_url: System.get_env("LITELLM_BASE_URL", "https://llm.zaq.ai")
else
  if url = System.get_env("USER_PORTAL_BASE_URL") do   # ← nested if-assignment pattern
    config :zaq, user_portal_base_url: url
  end
  if url = System.get_env("LITELLM_BASE_URL") do
    config :zaq, litellm_base_url: url
  end
end
```

**Fix:**  
Lift the URL config out of the prod guard. Both envs should default to the live URLs. Remove the `if config_env() == :prod` branching for just these two keys:

```elixir
config :zaq,
  user_portal_base_url: System.get_env("USER_PORTAL_BASE_URL", "https://portal.zaq.ai"),
  litellm_base_url: System.get_env("LITELLM_BASE_URL", "https://llm.zaq.ai")

if config_env() == :prod do
  # keep prod-only: SecretConfig, DATABASE_URL, Repo, etc.
end
```

---

## Step 6 — Ask reviewer to clarify `machine_fingerprint.ex`

**Reviewer comment:** `machine_fingerprint.ex` — "this is not a machine fingerprint... change it" (outdated)

The current code reads OS machine identifiers (Linux `/etc/machine-id`, macOS `IOPlatformUUID`, Windows registry `MachineGuid`) and falls back to a persisted random UUID. This is a legitimate fingerprint derivation. The reviewer's comment was on a now-outdated hunk.

**Action:** Reply on the GitHub thread asking the reviewer to re-comment on the current implementation and specify what needs to change before acting on this.

---

## Execution Order

```
Step 4 (client.ex)   — smallest, no callers change, do first
Step 5 (runtime.exs) — one-liner, independent
Step 1 (accounts.ex) — backend move, verify callers
Step 2 (change_password_live.ex) — depends on Step 3 design decision
Step 3 (consent modal) — depends on Step 2 (removes parent assigns)
Step 6 — ask reviewer, do not implement yet
```

Steps 4 and 5 can be done in a single commit. Steps 1–3 are logically related and should be reviewed together.

## Definition of Done

- [ ] `check_liveness/0` deleted from `UserPortal.Client`
- [ ] Non-prod runtime.exs uses `System.get_env(..., default)` pattern
- [ ] Portal provisioning functions removed from `Zaq.Accounts`, live in `Zaq.UserPortal.Provisioner`
- [ ] `ChangePasswordLive` has no `PortalClient` alias or direct portal HTTP calls
- [ ] Email regression fixed — always included in password change attrs
- [ ] `PortalConsentModal` loads its own metadata; parent passes only slug + callbacks
- [ ] `mix q` passes with no issues
