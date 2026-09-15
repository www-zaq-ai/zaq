# People profile

Last updated: 2026-09-15

## Current status

The production `/people/profile` is the canonical screen and review destination.
Approved cleanup removes the fixture preview route, simulations and fixture module.
Shared production components, hooks, CSS and Storybook variants remain. Settings
continues to show the approved “No personal settings available yet.” message.
Final UX approval (`zaq-tup.3`), consolidated E2E (`zaq-tup.4`) and physical drag /
keyboard-focus verification remain open.

## Revision log (historical decisions)

| Date | Source | Summary |
|---|---|---|
| 2026-09-15 | Explicit full promotion approval | Promote the entire reviewed profile to live `/people/profile`, including real persistence and the shared BO/People account menu. Login excluded. Final implemented UX approval for E2E remains pending. |
| 2026-09-15 | Approved correction | Extract BO avatar/initial plus display-name account menu into shared DSM AccountMenu; preview supplies fictional fixture name, BO supplies username. Shared disclosure behavior and configurable DOM IDs preserve callers. |
| 2026-09-15 | Human review | Reuse BO header presentation with title/description and theme, Settings and Profile controls; ZAQ logo at left, no sidebar. Settings approved as a preview-only placeholder. |

## 1. Product brief

**JTBD:** Understand my identity, team memberships and contact priority, and confidently update my name and preferred channel order when permitted.

**Users:** Existing authenticated People users, including nontechnical readers and editors. Preserve `access_profile` for viewing and both `access_profile` and `edit_profile` for editing. BO roles do not grant these capabilities.

**Concepts:** One current person has basic information, team memberships and owned contact channels. Channel priority means contact-attempt order, not cosmetic sorting. Existing ascending weight / ID tie-break order is the starting order.

**Scope:** Existing full name, email, phone, role and status; explicit name editing; alphabetically listed read-only teams; provider icons and identifiers; draft channel ordering with Save/Cancel; desktop width and mobile reflow.

**Header scope (review update):** Reuse a shared, extracted BO header presentation, not BOLayout's sidebar/authentication. Show the existing ZAQ logo at the left edge, a single Profile heading and description, existing system/light/dark selector, Settings placeholder, and a People Profile/sign-out dropdown. No BO administration destinations. This section is the accepted product brief; no separate PRD is maintained.

**Approved account correction:** Reuse the actual BO initial/avatar and name trigger in both headers. `AccountMenu` owns presentation and generic native disclosure enhancement; callers supply display name, profile URL, logout action and optional IDs/labels. People displays the authenticated profile's full name (safe “Profile” fallback for nil/blank), `/people/profile`, DELETE `/people/session`; BO displays username, `/bo/profile`, DELETE `/bo/session`. Keyboard activation, Escape with focus return, outside dismissal and mutual menu closing are shared. Panels stay within the viewport on mobile and desktop. Settings remains its separate unchanged placeholder; default PersonLayout/login stays unchanged.

**Exclusions:** New identity fields, membership editing, adding/removing channels, other people's profiles, permission changes and People login redesign. Production persistence is explicitly authorized by the latest review.

**Success:** Readers identify contact order without interpreting numeric weights. Editors can cancel without changing saved state. Keyboard and touch users can perform every reorder without dragging. Long names and identifiers do not cause horizontal scrolling. Login remains narrow.

**Production ordering contract:** One confidential `:update_self_channel_order` request carries the server-owned ordered integer IDs plus original ordered ID/weight snapshot. Person then channel-row locking protects fresh comparison; changed membership/order/weights returns `:stale_order` and reloads for review. Full current-owned permutations only; dense zero-based weights persist through changesets in one transaction. Existing single-weight API remains supported. Branded ChannelIcons are reused decoratively, including `microsoft_teams` → `teams` logo normalization and unknown-provider fallback.

## 2. Information architecture

User explicitly approved adapting the BO-oriented workflow to the **People** surface. No BO sidebar, BOLayout, or list of persons is appropriate.

| View | Route | Shell | page_title / current_path | Entry |
|---|---|---|---|---|
| Profile, including inline editing states | `/people/profile` | `PersonLayout.person_layout` with wide content | Profile / not consumed by this shell | Existing Profile navigation, sign-in redirect, deep link |

The profile uses real authenticated data and production persistence. Storybook uses
inline sample data for isolated presentation states; no simulation route is deployed.

## 3. User flows

### Flow: Read my profile
Actor: user with profile access. Trigger: Profile navigation. Goal: understand current information and contact order.
1. Profile → scan Basic information → see existing identity fields.
2. Teams → read alphabetical memberships; no edit affordance.
3. Contact channels → read numbered provider/identifier rows, first tried first.
Alternates: absent values show “Not provided”; empty lists show explicit section messages.
Failures: initial load shows status without blank forms; unavailable profile hides controls and offers Retry; access denied shows no personal information. Invalid session returns to existing sign-in flow.

### Flow: Edit name
Actor: authorized editor. Trigger: Edit name. Goal: update full name only.
1. Profile → Edit name → inline labeled field with current name and Save name / Cancel.
2. Edit → Save name → pending control → success, return to read mode.
Alternates: Cancel restores saved name; another editor mode cannot open while this draft exists.
Failures: validation keeps field and draft with an associated error; failed save keeps draft and Retry-by-save; revoked permission removes editing controls and explains why. Production backend validation remains authoritative.

### Flow: Change contact priority
Actor: authorized editor with at least two channels. Trigger: Change order.
1. Profile → Change order → draft ordered list, instructions, drag handles and Move up/down controls.
2. Move a channel → updated numbered position and polite announcement; saved state is unchanged.
3. Save order → pending state → success, exit edit mode. Save is disabled until order differs.
Alternates: Cancel restores original order; first/last unavailable moves are disabled; zero/one channel has no Change order action.
Failures: save failure preserves draft and offers retry/cancel; permission revocation exits edit mode. Concurrent membership/order changes prompt reload/review rather than overwrite silently through the production atomic ordering contract.

## 4. Screen: Profile

**Purpose:** Personal identity and contact preferences in one readable page.
**Route:** `/people/profile`.
**Entry:** Existing People navigation or direct review link.

### Layout zones

Desktop:
```text
+------------------------------------------------------------+
| [ZAQ] Profile             [Theme] [Settings] [Profile menu] |
|       Your information and how we contact you               |
+--------------------------+---------------------------------+
| Basic information        | Contact channels                |
| Full name    [Edit name] | Tried in the order shown        |
| Email                    | 1 [Provider icon] Platform      |
| Phone                    |   Identifier                    |
| Role / Status            | 2 [Provider icon] Platform      |
+--------------------------+   Identifier                    |
| Teams (count)            |                                 |
| Alphabetical team list   | [Change order]                  |
+--------------------------+---------------------------------+
```

Mobile (DOM and reading order):
```text
+------------------------------+
| [ZAQ] Profile                |
|       Description            |
| [Theme] [Settings] [Profile]  |
+------------------------------+
| Basic information            |
| Full name       [Edit name]   |
| Email / Phone / Role / Status|
+------------------------------+
| Teams (count)                |
| Membership list              |
+------------------------------+
| Contact channels             |
| Number / icon / label        |
| Identifier                   |
| [Change order]               |
+------------------------------+
```

Editing zones replace only the relevant block:
```text
+------------------------------+
| Full name                    |
| [Current or draft name     ] |
| Field error (when invalid)   |
| [Save name] [Cancel]         |
+------------------------------+
| Contact channels: draft      |
| Drag or use move buttons     |
| [Handle] 1 Icon / Platform   |
| Identifier      [Up] [Down]  |
| Unsaved order / announcement |
| [Save order] [Cancel]        |
+------------------------------+
```

### Content blocks
| Block | Content | Notes |
|---|---|---|
| Header | ZAQ logo, Profile, purpose sentence; theme, Settings, Profile menu | Shared BO presentation; one h1; no sidebar; People owns destinations/logout |
| Basic information | Full name, email, phone, role, status | Definition list; long values wrap; name only editable |
| Teams | Count and names | Alphabetical semantic list; no membership links/actions |
| Channels | Position, provider logo, provider name, identifier | Ordered list; duplicate providers remain distinguishable by identifier |
| Draft actions | Save/Cancel, unsaved message | One editor at a time; no autosave |

### Interactions
| Element | Action | Result |
|---|---|---|
| Edit name | Activate | Focus name field; replace static name with form |
| Save name | Submit | Validate and persist through the authenticated profile gateway |
| Change order | Activate | Draft mode; focus instruction/list area |
| Drag handle | Drag onto channel | Move dragged channel to target position |
| Move up/down | Click, keyboard or touch | Move one position; retain focus within moved row |
| Save order | Activate | Persist the complete draft atomically after fresh authority and snapshot checks |
| Cancel | Activate | Restore saved value/order and focus initiating action |
| Retry | Activate | Reload the authenticated profile |
| Theme selector | Choose System, Light or Dark | Existing root theme handling; device-local preference, no backend |
| Settings | Open disclosure | “No personal settings available yet.”; no action or BO links |
| Profile menu | Open disclosure | Link to real `/people/profile` and existing People sign-out; never `/bo/session` |
| ZAQ logo | View | Non-interactive brand mark; no BO-home destination |

### States
| State | When | What user sees |
|---|---|---|
| Default | Authorized editor | Read mode with name and order entry actions |
| Read-only | No edit grant | All information; explanatory notice; no edit/move/save controls |
| Empty | No teams/channels; absent optional fields | No teams; No channels; Not provided |
| Single channel | One channel | Position 1; no order editor |
| Loading | Initial load | Loading profile status; no controls |
| Unavailable | Profile service failure | Unavailable message, Retry; no stale editable content |
| Denied | No profile access | No personal details; permission explanation |
| Invalid name | Rejected input | Draft retained; field-level error |
| Save error | Save failure | Draft retained when fresh authorization confirms safe retry; actionable error, no success claim |
| Revoked editing | Editing permission lost | Saved view, no controls, explanation |
| Long content | Long names/IDs, multiple memberships, unknown provider | Wrapping list rows; fallback icon with explicit label |

### Copy hints
- “Contact channels”; “We try your channels in the order shown.”
- “Drag a handle or use Move up and Move down. Changes apply only when you save.”
- “Order changed. Save to apply your preferences.”
- “This profile is read-only. Contact your administrator to request edit permission.”
- Success is shown only after confirmed production persistence.

### Accessibility
Heading order h1 → section h2; semantic dl, ul and ol. Icons are decorative beside platform labels. Move button accessible names include platform and identifier. Live announcements include new position and total. Disabled boundaries are represented semantically. Keyboard focus follows the moved row and returns after cancel/save. Wrapping must preserve reading order without horizontal scrolling. Dragging is optional, never the only input method.

## 5. Component mapping

Inventory cross-checked against DESIGN.md, docs/bo-components.md and production Storybook sources. Components below are implemented.

| UX need | Existing component / pattern | Gap? |
|---|---|---|
| Shell and feedback | `ZaqWeb.Components.PersonLayout.person_layout` | Opt-in wide content; narrow default unchanged |
| Shared header chrome and heading | `ZaqWeb.Components.DesignSystem.PageHeader.page_header` and `page_heading` | Extracted from BOLayout; `brand`, `heading`, `context`, `actions` slots; heading takes title/description and icon/tag/subtitle slots; no auth or route knowledge |
| Theme selector | `ZaqWeb.CoreComponents.theme_toggle` | Reuse existing theme events; add accessible names to icon buttons |
| People header composition / Settings | `ZaqWeb.Components.DesignSystem.PersonHeader.person_header` | Compose PageHeader and AccountMenu; caller passes authenticated display name; separate Settings placeholder unchanged |
| Shared account trigger and dropdown | `ZaqWeb.Components.DesignSystem.AccountMenu.account_menu` | Extracted BO avatar/name markup; caller-owned name/routes/logout and customizable IDs/labels; native details/summary with shared Escape/outside/mutual dismissal and viewport positioning, no BO/People branches |
| ZAQ brand | Existing `/images/zaq.png` asset in PersonHeader brand slot | Meaningful alt text; no sidebar or home link |
| Section cards | DESIGN card CSS `.zaq-card-default` with semantic section headings | Existing CSS shell; no invented card module |
| Identity values | Semantic dl using DESIGN typography/layout utilities | No specialized component needed |
| Memberships | Semantic ul using DESIGN stack utilities | Read-only list, not a table or picker |
| Actions | `ZaqWeb.Components.DesignSystem.Button.button` | None |
| Provider logos | `ZaqWeb.Components.ChannelIcons.icon` | Existing logos/fallback; decorative wrapper; /design review of brand exception |
| Empty lists | `ZaqWeb.Components.DesignSystem.EmptyState.empty_state` | None |
| Ordered channel rows and controls | `ZaqWeb.Components.DesignSystem.ChannelPriorityList.channel_priority_list` | Parent-controlled `id`, `channels`, `editing`; move event carries owned row ID + direction or target ID; polite announcement belongs to parent |
| Drag and focus | Colocated PriorityDrag in ChannelPriorityList and ProfileFocus in PersonProfile | Implemented progressive drag and focus enhancement; visible move buttons support touch/keyboard; physical drag and keyboard-focus verification remains open |

## 5b. Form field mapping

| Screen | Field | Control (module) | Gap? |
|---|---|---|---|
| Profile: edit name | Full name | `ZaqWeb.Components.DesignSystem.Input.input`, text, label Full name, autocomplete name | None; errors supplied to existing component |
| Profile: change order | Channel priority | `ZaqWeb.Components.DesignSystem.ChannelPriorityList.channel_priority_list` | Implemented ordered control, not raw numeric inputs/selects |

No other editable fields.

## 6. UX decisions log (historical)

These decisions record the initial staging pass. Preview routes, fixture-only saves
and deferred persistence below were superseded by production promotion and cleanup;
they are not instructions to recreate staging.

1. Keep PersonLayout: it is a person-facing shell, not a people list. User explicitly confirmed reuse with independent profile content and opt-in width.
2. Keep Teams read-only and preserve existing fields and permission model (confirmed by user).
3. Channel order expresses contact priority with explicit Save/Cancel (confirmed by user). Display rank rather than raw weights; backend mapping deferred.
4. Use a wider desktop grid and single mobile stack, preserving DOM reading order. No final colors, type scales or pixel spacing chosen here.
5. Only one editor at a time prevents conflicting Save actions and accidental loss of another draft.
6. Add protected `/people/profile/preview` rather than substituting fixture identities at the live profile route. No real profile updates in this pass.
7. No polling promised. Preview changes are session-memory-only and reset on scenario changes/reload.
8. Human approved shared BO header presentation with no sidebar. Extract its presentational seam; BO callers retain their existing icon/subtitle/context/action slots and destinations.
9. Settings has no People backend destination: user selected a clearly labeled preview placeholder. Approved correction supersedes the generic Profile trigger: show the explicitly fictional preview profile name using the same avatar/name component as BO; preserve real People sign-out. Final UX approval and E2E remain pending (`zaq-tup.6` → `.3` → `.4`).

## Historical UI Designer Brief

This initial build brief is retained as history. Its staging instructions and gap
labels are superseded by the production implementation and current DESIGN inventory.

### Build order
1. Opt-in shell width and static profile hierarchy — establishes responsive structure without changing login.
2. Information and Teams sections — simplest read/read-only states.
3. Name editor — clear edit affordance and validation.
4. ChannelPriorityList — icons, long identifiers, accessible draft interactions.
5. All scenario states and desktop/mobile inspection.

### Design system constraints
- Approved non-BO exception: `PersonLayout.person_layout`, not BOLayout.
- `--zaq-*` only; see DESIGN.md. Reuse Button, Input, EmptyState and ChannelIcons.
- Prototype component gaps are staging, not final design-system contracts.

### Stories to add/update in /design (not prototype)
- [ ] PersonLayout narrow/wide variants, mobile navigation.
- [ ] Shared PageHeader with/without brand, subtitle/tag/icon slots, wrapping actions, and People disclosures (after prototype review).
- [ ] ChannelPriorityList: read, editing, boundaries, unknown/duplicate providers, long identifiers.
- [ ] Name-edit pattern: default, invalid, saving and failed save.
- [ ] Empty and read-only profile composition.

### Open for visual design
- [ ] Section emphasis and desktop column balance.
- [ ] Channel row density, drag affordance and drop feedback.
- [ ] Icon branding exception and keyboard focus visibility.

### Out of scope for UI pass
Batch persistence, concurrency resolution, auth changes, new profile fields, membership/channel management.

### Prototype handoff
`/prototype` implements §5 and §5b verbatim, resolving modules against DESIGN.md at build time. Non-gap rows use those modules. **[NEW COMPONENT]** / **[GAP]** rows become DSM implementations or explicitly documented interim patterns for /design. No raw form inputs/selects. No backend calls in fixtures or preview handlers. Existing route-level authentication remains outside the prototype.

### Next step
Review the implemented real `/people/profile` on desktop/mobile. Full production promotion was approved and applied; final implemented UX approval still gates consolidated E2E authoring (`zaq-tup.3` → `zaq-tup.4`). Earlier prototype-only descriptions and validation notes below are historical. Execution tracking lives in Beadwork.

## Approved cleanup validation — 2026-09-15 (`zaq-tup.12`)

- Removed preview route/LiveView, fictional scenarios and simulation tests. The
  component suite uses local sample rows; direct ChannelOrder properties already
  cover membership, target position and unaffected relative order. New no-route
  regression failed before cleanup and passed afterward. Production tests retain
  their assertions, including login/default layout, persistence, grants and gateway.
- `mix format`, `mix q` (1,252 sources, no issues), `mix assets.build` and
  `git diff --check` passed. Main complete scoped `mix coveralls.json` run:
  **7 properties, 367 tests, 0 failures**. Supplemental complete authentication,
  permissions and permission-concurrency suites: **4 properties, 30 tests, 0 failures**.
  Exact suite paths are in the handoff. These replace earlier staging counts;
  they are scoped runs, not the entire repository suite.
- Fresh main-run coverage: ProfileLive **96.8%**, PeopleAuthGateway **98%**;
  ChannelOrder, PersonLayout, PersonHeader, PersonProfile, PageHeader, AccountMenu,
  ChannelPriorityList and People LoginLive **100%**. Cleanup adds no production
  logic. Scoped legacy exceptions remain under `.10`: People **90.1%**, BOLayout
  **86.4%**, CoreComponents **6.7%** (older context/helpers outside cleanup scope).
  JavaScript is not measured by ExCoveralls. Existing `:license_manager` warning persists.
- Signed-in live profile loaded read-only; removed URL displayed Phoenix's expected
  development `NoRouteError` page. No real profile edits or sign-out were performed.
  Final UX `.3` and E2E `.4` remain open; remaining physical drag / keyboard-focus
  checks stay in `.2`. Existing E2E is untouched; no new feature E2E authored.

## Production promotion — 2026-09-15 (historical validation before cleanup)

- **Independent audit correction (`zaq-tup.11`):** BO swaps previously used stale struct weights despite channel row locking. They now acquire literal Person owner locks before ordered channel locks and reread current weights. Cross-owner trusted swaps retain their semantics; changed ownership/missing rows reject. Deterministic transaction/message-barrier tests prove reorder→swap yields the serial C0/A1/B2 result and swap→reorder rejects the stale draft, without sleeps. Both the stale-value and concurrency regression failed before the fix and pass afterward.
- **Post-audit validation:** `mix format` and `mix q` passed; complete prior scoped suites plus new regressions and the full BO PeopleLive caller suite passed: **10 properties, 333 tests, zero failures (343 cases)**. The earlier 260-case result and coverage percentages below are historical pre-audit measurements; coverage was not remeasured for this correction. Existing `license_manager` warning remains. Validation `.7` was reopened during the correction; final human approval `.3`/E2E `.4` remain open.
- Final validation: `mix format`, `mix q` (1,255 source files, no issues), `mix assets.build` and `git diff --check` passed. Complete affected scoped suites plus coverage: **10 properties, 250 tests, 0 failures**. The existing unavailable `:license_manager` configuration warning remains. Legacy coverage follow-up: `zaq-tup.10`.
- Replaced live profile markup with shared `PersonProfile`, also used by preview. `ProfileLive` imports no fixtures. The real header uses `PersonHeader`/`PageHeader`/`AccountMenu` and real identity; no sidebar, BO destinations, review controls or fixture notices.
- Applied the approved inline name editor and single channel-order editor, with parent-owned drafts, Save/Cancel, generic moves, permission-revocation cleanup, focus events and field-error retention. Blank names retain backend semantics. Teams remain read-only. Login and default PersonLayout behavior were not edited in this promotion.
- Atomic command and locking/staleness contract are documented in `docs/services/people-access.md`. Tests exercise real simultaneous drafts, insertion/deletion/legacy-weight writers, late database failure rollback, malformed/foreign/incomplete orders, authorization and confidential event diagnostics/broadcast suppression. A real database name-write failure verifies draft retention and recovery.
- Added production Storybook PersonHeader and PersonProfile variants and DESIGN inventory. Variants use isolated iframes because profile/header IDs are page-scoped; inline variants initially produced duplicate-ID diagnostics and were corrected.
- New production coverage from the scoped suites: ProfileLive **96.8% (92/95)**, PeopleAuthGateway **98% (49/50)**; PersonProfile **42/42**, PersonHeader **9/9**, PageHeader **25/25**, AccountMenu **21/21**, ChannelPriorityList **23/23**, ChannelOrder **13/13**, PersonLayout **16/16**. Preview **98.3% (59/60)**. The new atomic People function's relevant lines are covered; whole People remains **86.7% (254/293)** because older selection/discovery/resource/team branches are outside this suite. BOLayout **84.3% (118/140)** and CoreComponents **6.8% (11/162)** retain legacy helper gaps. These are scoped figures, not whole-repository success claims; JavaScript is not measured by ExCoveralls.
- Residual covered-scope branches: ProfileLive transport exit and permission/staleness changing during transient-error recovery; PeopleAuthGateway legacy delivery validation failure; preview validate-name handler. Main denial/stale/recovery paths are exercised independently.
- Browser read-only inspection reached live profile at desktop 1440 and mobile 390, displaying the signed-in person's name, real channels and empty teams. Mobile content measured x=24, width=342 inside 390px. Preview move-button reordering produced the correct new rank and announcement; Save was activated only on fixtures. Hot reload reset preview state before a durable post-save observation. Physical drag, keyboard/Escape/focus and final visual sign-off remain unverified. OpenChamber occasionally returned stale/scaled geometry; do not treat those snapshots as overflow measurements.
- Existing `people-auth-browser.cjs` assumes numeric priority `5`, always-visible name inputs and old header/copy. Updating that journey requires behavioral changes beyond minimal selector repairs, so it remains untouched pending final approval `.3` and consolidated E2E `.4`. No new E2E was authored and no real user name/priorities were changed or user signed out.

## Prototype validation — 2026-09-15 (historical; preview removed)

- Staged at `/people/profile/preview`; real `/people/profile` unchanged.
- `mix format`, `mix q`, `mix assets.build` and `git diff --check` passed.
- Focused fixture/component/LiveView tests plus existing profile regression tests: 1 property and 19 tests, zero failures. Targeted coverage reports 100% for PeopleProfile fixtures, ProfilePreviewLive and PersonLayout; aggregate repository coverage from this targeted run is not a full-suite coverage measurement.
- Browser reached the existing People sign-in screen at `http://localhost:4010/people/login`. Authenticated visual inspection is blocked pending sign-in; desktop/mobile overflow, actual drag behavior and browser focus are not yet verified.
- Review scenarios are accessible through the preview's “Review scenarios” disclosure. Scenario navigation/reload resets fixture edits. No production save, Storybook update, or new E2E journey has been implemented.

### Header iteration validation — 2026-09-15

- Supersedes the sign-in blocker above: user signed in, and authenticated preview was inspected at desktop 1440px and mobile 390px.
- Shared PageHeader is used by BOLayout and PersonHeader. People has ZAQ branding, one heading/description, named theme controls, approved Settings placeholder and People-only account actions; no sidebar.
- Browser verified dark/light changes, Settings/Profile disclosure content, outside-click dismissal, mobile menu bounds, name editor/cancel, and move-button reorder followed by Save. Physical drag/drop, keyboard focus/Escape and the remaining fixture scenario browser matrix still need dedicated verification.
- Fixed missing prototype hook registration in `assets/js/app.js` using explicit People-only opt-ins. Fixed Settings positioning by anchoring both menus to the account navigation, and applied existing raised/bordered panel classes so menu content is not transparent.
- Latest `mix format`, `mix q`, `mix assets.build` and focused suite passed: 1 property + 31 tests, zero failures. Existing BO header and production People profile assertions were preserved.
- Targeted coverage: PersonLayout and ProfilePreviewLive 100%. BOLayout 84.6% and CoreComponents 6.7% in this focused run reflect unexercised legacy helpers outside this header change; this is not a full-suite result. Full legacy-module coverage remains a hardening follow-up, not a claim of meeting the whole-file target.

### Shared account correction validation — 2026-09-15 (`zaq-tup.6`)

- BOLayout and PersonHeader now reuse `AccountMenu` with the existing BO initial/avatar and name presentation. All BO menu/trigger/panel/profile/logout IDs remain intact. People receives `@profile.person.full_name`, including fixture edits and nil fallback; account routes and DELETE logout remain caller-owned.
- `mix format` and `mix q` passed (1,251 source files checked; no issues). `mix assets.build` and `git diff --check` passed.
- Targeted suites: AccountMenu, PageHeader, ChannelPriorityList, BOLayout, ProfilePreviewLive, existing production ProfileLive and PeopleProfile fixtures: **2 properties, 34 tests, 0 failures**. Coverage runs (`mix test --cover` and `mix coveralls.json` with the same suites) also passed. Elixir coverage: AccountMenu 21/21, PersonHeader 9/9 and ProfilePreviewLive 94/94 relevant lines (100%); BOLayout 84.2% due to legacy helpers. JavaScript behavior is not measured by ExCoveralls.
- Signed-in browser inspection verified fictional Alex Morgan/A trigger, account content, Settings/account mutual dismissal and outside dismissal. Account panel measured x=1184, width=224 in desktop 1440px, and x=134, width=224 in mobile 390px; both viewport-contained. Mobile resize initially returned stale desktop geometry; reopening with mobile viewport resolved it. No page errors were reported in snapshots.
- Keyboard activation uses native details/summary; shared hook implements Escape/focus return, focus-out dismissal and resize/scroll positioning. Keyboard/Escape were not exercised by the available OpenChamber interaction API. Long-content browser matrix, physical drag and final human UX approval remain pending with `.2`/`.3`; consolidated E2E `.4` remains blocked. Tests still report the pre-existing unavailable `:license_manager` configuration warning.
