# Component extraction — review table & phased plan

This document captures the **candidate BO/UI slices** from the `/extract` analysis, plus a **two-phase plan**: strengthen E2E where coverage is missing or partial, then **extract only rows you approve** (per [`.claude/skills/extract/SKILL.md`](.claude/skills/extract/SKILL.md)).

---

## Review table

| # | Proposed slice name | Occurrences | Function (user-facing role) | Suggested module `ZaqWeb.Components.DesignSystem.*` | Tests raw UI | E2E spec(s) | E2E coverage | E2E notes | Storybook | Definition (standalone file vs inside larger scope) |
|---|---------------------|-------------|------------------------------|-----------------------------------------------------|--------------|-------------|--------------|-----------|-----------|--------------------------------------------------------|
| 1 | BO modal primitives (`form_dialog`, `modal_shell`, `confirm_dialog`) | Many `.heex` / tab `.ex` consumers; several instances per page on e.g. `channels_live`, `provider_live` | Modal chrome for forms, custom bodies, destructive confirms | e.g. `BackOfficeModal` or split `ModalShell` / `ModalForm` / `ModalConfirm` | partial | `agents.spec.js`, `people.spec.js`, `ingestion.spec.js`, `system_config.spec.js`, `onboarding.spec.js` | partial | Only some flows assert specific modals/ids; not every variant | **Partial** — `Storybook.Components.Modals.BoModal` + `Storybook.BoModal.ConfirmDialog` (`confirm_dialog` only); `modal_shell` illustrated via `Storybook.Components.FilePreview.FilePreviewModal`; **no** dedicated `form_dialog` story | **Standalone file** — `lib/zaq_web/components/bo_modal.ex` (`ZaqWeb.Components.BOModal`). **One module, several function components** in that file — not embedded in a LiveView. |
| 2 | Searchable combobox | 7 import sites (`agents_live`, `people_live`, `conversation_filters`, `modal_share`, four `system_config/*_tab.ex`) | Typeahead select for long lists | `SearchableSelect` | yes | `agents.spec.js`, `people.spec.js`, `system_config.spec.js` | covered | `pickSearchableSelect` + `[data-select-trigger]` / `[data-select-option]` | **Yes** — `Storybook.Components.Forms.SearchableSelect` (`components/forms/searchable_select.story.exs`, `:page`) | **Standalone file** — `lib/zaq_web/components/searchable_select.ex`. Not defined inside another component/live file. |
| 3 | Master–detail shell | 2 pages: `agents_live`, `people_live` | Two-pane list + detail | `MasterDetailLayout` | partial | `agents.spec.js`, `people.spec.js` | partial | Flow tests; wrapper markup may be implicit | **Yes** — `Storybook.Layouts.MasterDetail` (`layouts/master_detail.story.exs`, `:page`) | **Standalone file** — `lib/zaq_web/components/master_detail_layout.ex`. Not embedded elsewhere. |
| 4 | Chat bubbles + message chrome | 4 areas: `transcript.ex`, `conversation_detail_live`, `chat_live`, `shared_conversation_live` | User/assistant messages, copy/feedback, info popin | `ChatMessage` | partial | `knowledge_ops_lead.spec.js` (and related chat/history flows) | partial | Not every sub-piece asserted | **Yes (several)** — e.g. `Storybook.Chat.UserBubble`, `AssistantBubble`, `MessageInfoPopin`, `Transcript` under `storybook/chat/*.story.exs` | **Standalone file** — `lib/zaq_web/components/chat_message.ex`. **One module, many function components** in that file — still a dedicated component file, not a LiveView-local block. |
| 5 | File preview (inline + modal) | Modal: `ingestion_live`, `chat_live`, `conversation_detail_live`; inline: `file_preview_live` + composition in `FilePreviewModal` | Open/read files from KB/chat | `FilePreview` + `FilePreviewModal` | yes | `ingestion.spec.js`, `knowledge_ops_lead.spec.js`, `history.spec.js` | covered | `#file-preview-modal` and preview controls in e2e | **Yes** — `Storybook.Components.FilePreview.FilePreview` + `.FilePreviewModal` (`components/file_preview/*.story.exs`) | **Standalone files** — `lib/zaq_web/components/file_preview.ex` and `file_preview_modal.ex` (two modules/files). Not embedded in a non-component file. |
| 6 | Channel provider icon | 2 pages; 4× on `channels_index_live` | Channel identity in lists/cards | `ChannelIcon` | no | — | none | No `channels*.spec.js` | **Yes** — `Storybook.Components.Icons.ChannelIcons` (`components/icons/channel_icons.story.exs`, `:page`) | **Standalone file** — `lib/zaq_web/components/channel_icons.ex`. |
| 7 | Channel capability chip + modal | 2 pages: `provider_live`, `channels_live` | Capability snapshot; opens modal | `ChannelCapabilities` | no | — | none | No channels e2e spec | **Yes** — `Storybook.Modals.ChannelCapabilities` (`modals/channel_capabilities.story.exs`, `:component`) | **Standalone file** — `lib/zaq_web/components/channel_capabilities.ex`. |
| 8 | Connect credential form | 2: `connect_credentials_tab.ex`, `provider_live.html.heex` | Create/edit connector credentials | `ConnectCredentialForm` | no | — | none | Parent system-config e2e may not touch this subtree | **Yes (pattern)** — `Storybook.Patterns.Credentials` (`patterns/credentials.story.exs`, `:page`) | **Standalone file** — `lib/zaq_web/components/connect_credential_form.ex`. |
| 9 | Portal consent + post-accept modals | 2 LiveViews: `portal_consent_live`, `change_password_live` | Portal / consent gating | `PortalConsentModal` | yes | `onboarding.spec.js` | covered | Preserve `phx-click` / `#portal-consent-email` etc. | **No** | **Standalone file** — `lib/zaq_web/components/portal_consent_modal.ex`. |
| 10 | Password requirements panel | 2× on one page: `user_form_live.html.heex` | Inline password policy checklist | `PasswordRequirements` | no | — | none | ExUnit possible; no e2e on this panel | **Yes** — `Storybook.Components.Forms.PasswordRequirements` (`components/forms/password_requirements.story.exs`, `:component`) | **Standalone file** — `lib/zaq_web/components/password_policy_components.ex`. |

**Definition column note:** all listed candidates already live in **standalone** `lib/zaq_web/components/*.ex` files. Rows **1** and **4** are “one file, multiple function components” under one module — still not LiveView-embedded fragments.

---

## Phased plan

### Phase 0 — Your approval (gate)

1. Reply in the PR / issue / chat with **approved row numbers** (e.g. “approve 6, 7, 8”) or edits (merge/split/cancel).
2. Optionally mark rows as **“E2E only”** (no extraction) vs **“E2E + extract”**.

Until approval, **do not start DesignSystem extraction** for those rows (per extract skill human gate).

---

### Phase 1 — E2E first (rows with `none` or `partial` coverage, or `Tests raw UI` = `no` / `partial`)

**Goal:** Before moving markup or renaming modules, add or extend Playwright coverage so approved slices have **stable selectors** and **at least one happy-path assertion** per consuming route where practical. Follow [`docs/e2e-testing.md`](docs/e2e-testing.md) and existing patterns in [`test/e2e/support/bo.js`](test/e2e/support/bo.js).

| Priority | Row # | Why | Suggested e2e direction |
|----------|-------|-----|------------------------|
| P1 | **6**, **7** | **E2E coverage: none** — no spec file for channels/provider flows that exercise these components | Add `test/e2e/specs/channels.spec.js` (or `providers.spec.js`) with minimal navigation from BO login to a route that renders `ChannelIcons` and `ChannelCapabilities.icon_with_modal`; assert visible icon + modal open/close using stable `data-testid` or roles **without** changing product behavior unless ids are missing (then add testids in `lib/zaq_web` as part of the same PR). |
| P1 | **8** | **E2E coverage: none** for the form subtree | Extend **`system_config.spec.js`** (or new focused spec) to open **Connect credentials** (or provider) tab and assert `ConnectCredentialForm` markers + one validate/save or cancel path. |
| P1 | **10** | **Tests raw UI: no** | Extend **`people.spec.js`** or **`user_form`**-related flow if e2e reaches user create/edit; otherwise add a small spec that loads the user form route in e2e seed state and asserts the password requirements panel DOM (checklist / pass-fail). If no e2e route exists for `user_form_live`, document **manual smoke** + ExUnit in the PR until a route is e2e-seeded. |
| P2 | **1** | **partial** — many `BOModal` variants untested | Pick **one** `form_dialog` and **one** `modal_shell` path not already covered (e.g. channels or provider) and add assertions for overlay + primary action; keep ids/`phx-click` contracts stable. Add **`form_dialog`** Storybook later in same or follow-up PR. |
| P2 | **3** | **partial** — layout wrapper implicit | In `agents.spec.js` / `people.spec.js`, add a **narrow** assertion on a stable attribute on `MasterDetailLayout` root (add `data-testid` on the component if missing) so refactors do not regress layout. |
| P2 | **4** | **partial** | Extend **`knowledge_ops_lead.spec.js`** or **`history.spec.js`** to assert one **ChatMessage** affordance (e.g. copy button, feedback control, or bubble container) via stable selector. |

**Skip / defer Phase 1 e2e work** for rows you do **not** approve, and for rows already **covered** with **Tests raw UI: yes** unless you want redundancy:

- **Row 2** (SearchableSelect), **Row 5** (File preview), **Row 9** (Portal consent) — already strong e2e for the slice’s behavior.

**After Phase 1 for a given row:** re-run the relevant spec(s) from [`test/e2e/specs/`](test/e2e/specs/) and update this doc’s table (coverage column) in the PR description or a short follow-up commit.

### Phase 1 implementation status (e2e-only pass)

Implemented in repo (run locally with Postgres on `localhost:5432` per `docs/e2e-testing.md`):

| Row | Change |
|-----|--------|
| 1 (partial) | `channels.spec.js` exercises `BOModal.form_dialog` via **Capabilities** modal (`#capabilities-modal`) open/close. |
| 3 (partial) | `[data-testid="bo-master-detail-layout"]` on `MasterDetailLayout`; asserted in **`agents.spec.js`** and **`people.spec.js`**. |
| 4 (partial) | `[data-testid="chat-assistant-bubble"]` / `chat-user-bubble` on `ChatMessage` bubbles; asserted in **`knowledge_ops_lead.spec.js`** (Journey 1 + Journey 4). |
| 6–7 (none) | **`channels.spec.js`**: index icon strips (`data-testid` on retrieval/data-source rows); provider **Capabilities** trigger (`data-testid="channel-capabilities-trigger"`). |
| 8 (none) | **`channels.spec.js`**: Google Drive provider → New Config → **New credential** → `#connect-credential-form`. **`system_config.spec.js`**: **Auth Credentials** tab navigation + heading. |
| 10 (no raw UI) | **`users.spec.js`**: `/bo/users/new` → password typing → `#password-requirements` + checklist items. |

---

### Phase 2 — Extraction (only rows you approved)

**Preconditions**

- Phase 1 complete **for that row** *or* you explicitly waived e2e (“extract without new e2e”) in writing.
- `mix q` green; targeted `npx playwright test …` for touched specs.

**Steps (per approved row)** — align with extract skill:

1. Add `lib/zaq_web/components/design_system/<snake>.ex` with `ZaqWeb.Components.DesignSystem.<Name>` (or agreed name).
2. Move `~H"""` + helpers used **only** by that slice; preserve **e2e ids**, **event names**, and **assigns contract**.
3. New layout/color utilities → **`assets/css/styles.css`** only; use `--zaq-*` / `.zaq-*` (and **design-migrate** if token work is in scope).
4. Import at call sites; remove dead code from old modules; **`mix format`**.
5. **Storybook:** `storybook/components/design_system/<snake>.story.exs` + index updates; **row 9** needs a **new** story for `PortalConsentModal` if you approve it.
6. Verify: **`mix q`**; run e2e specs derived from consuming LiveViews (`docs/e2e-testing.md` + extract skill §8).

**Coordination:** if the main goal is token migration, **extract first**, then **design-migrate** on the new component files (extract skill).

---

## Human gate (reminder)

Reply with **approved row #s**, **E2E-only vs E2E+extract**, and any **waivers**. Extraction work starts only after that list is explicit.
