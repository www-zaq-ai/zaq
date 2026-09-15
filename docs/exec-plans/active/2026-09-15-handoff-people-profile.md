## 1. Goal

Promote the explicitly approved entire redesign to real `/people/profile`: shared account/header, layout, inline name Save/Cancel, read-only teams, provider icons and atomic ordered channels. Production persistence was explicitly authorized; People login is excluded. Preserve pre-existing uncommitted work and deliver only working-tree edits.

## 2. Current State

**Approved cleanup (`zaq-tup.12`) supersedes the historical prototype-only notes below.**

Canonical live/review URL: `http://localhost:4010/people/profile`. Removed the staging
route, preview LiveView, fictional fixture module and simulation suites. Component
tests now use local representative rows. Existing direct ChannelOrder properties
already subsume the deleted fixture ordering invariant; none were weakened.
A new routing regression failed before removal and protects the retired URL.
Production components/hooks/CSS and both Storybook stories remain in use. The
approved Settings message remains. Final approval `.3`, E2E `.4`, and outstanding
physical drag / keyboard-focus checks remain open against the production UI using
dedicated test identities when mutations are needed.

**Verified cleanup results:** `mix format`, `mix q` (1,252 sources, no issues),
`mix assets.build`, `git diff --check` passed. Main `mix coveralls.json`:
**7 properties, 367 tests, zero failures**. Supplemental `mix test`:
**4 properties, 30 tests, zero failures**. Existing `:license_manager` warning persists.
Fresh main coverage: ProfileLive 96.8%, PeopleAuthGateway 98%; ChannelOrder,
PersonLayout, PersonHeader, PersonProfile, PageHeader, AccountMenu,
ChannelPriorityList and People LoginLive 100%. Scoped legacy exceptions under `.10`:
People 90.1%, BOLayout 86.4%, CoreComponents 6.7%; no JavaScript coverage claim.
Browser read-only live profile loaded signed in; retired URL displayed the expected
Phoenix development NoRouteError. No real name/order mutation or sign-out.

Main complete suite paths passed to `mix coveralls.json`:

- `test/zaq/accounts/`: `people_test.exs`, `people_self_profile_test.exs`,
  `people_channel_order_concurrency_test.exs`, `people_auth_merge_test.exs`,
  `people_auth_concurrency_test.exs`.
- `test/zaq/engine/`: `people_profile_gateway_test.exs`, `people_auth_gateway_test.exs`,
  `people_gateway_test.exs`, `api_test.exs`.
- `test/zaq_web/`: `live/people/profile_live_test.exs`, `channel_order_test.exs`,
  `people_profile_routing_test.exs`, `components/design_system/account_menu_test.exs`,
  `components/design_system/page_header_test.exs`,
  `components/design_system/channel_priority_list_test.exs`,
  `components/bo_layout_test.exs`, `controllers/person_session_controller_test.exs`,
  `live/bo/system/people_live_test.exs`.
- Supplemental `mix test`: `test/zaq/accounts/people_auth_test.exs`,
  `test/zaq/accounts/people_permissions_test.exs`,
  `test/zaq/accounts/people_permissions_concurrency_test.exs`.

Executable source/test search found no fixture-module or preview-LiveView references;
the retired URL remains only in its deliberate routing regression. DESIGN inventory
and production hooks remain valid. Historical notes below are not staging instructions.

**Latest independent-audit correction (`zaq-tup.11`):** fixed stale BO swaps in
`People.swap_channel_weights/2`. The operation locks supplied literal Person owners
in ascending ID order, then current owned channel rows in ascending ID order,
verifies ownership, and swaps fresh weights. Trusted cross-person swaps, return
envelope and activity behavior are preserved; deleted/transferred coordinates fail
with `:not_found`. Added deterministic held-transaction reorder/swap tests for both
serial outcomes and stale-snapshot rejection, plus stale/cross-owner/missing tests.
The reproducing tests failed before implementation and passed after it.

Pre-cleanup full validation: **10 properties, 333 tests, zero failures (343 cases)**,
including all prior scoped suites and the full BO PeopleLive caller suite.
`mix format`, `mix q` and diff checks passed. Earlier coverage numbers below are
pre-audit measurements and were not remeasured for the swap correction. `.7` was
reopened while the P2 was fixed; `.3`/`.4` remain final human/E2E gates.
No real-user mutations, commits or pushes; pre-existing working-tree edits preserved.

- `ProfileLive` uses the approved shared PersonHeader/account menu and presentational `PersonProfile`. The pure `ZaqWeb.ChannelOrder` helper owns generic moves, with no fixture dependency. Default PersonLayout and People login received no edits in this promotion or cleanup.
- `People.update_self_channel_order/3` and its confidential `PeopleAuthGateway` operation accept a complete ordered integer-ID permutation plus original ordered ID/weight snapshot. Literal Person `FOR UPDATE` then channel rows by ID `FOR UPDATE` protect comparison and changeset writes. FK locks serialize inserts, row locks cover legacy writes/deletes; stale membership/order/weights rejects. Dense zero-based weights commit atomically. Current bearer-derived identity/grants/session are rechecked in the existing outer gateway transaction.
- Unit/integration/LiveView/property coverage includes simultaneous drafts/writers, late DB rollback, malformed/foreign/stale payloads, nil/session/edit revocation, confidentiality, real menu identity, name optional blank/error/cancel, order cancel/guards and read-only teams. Genuine DB name failure is caught without logging request data; fresh read preserves draft for retry.
- Final `mix format`, `mix q` (1,255 sources, no issues), assets build and diff check passed. Last complete affected scoped coverage run: **10 properties, 250 tests, 0 failures**, including late-order rollback. Results are recorded in Beadwork `.7` and UX notes. Coverage: ProfileLive 96.8%, PeopleAuthGateway 98%, new pure/presentational components 100%; legacy People 86.7%, BOLayout 84.3%, CoreComponents 6.8%. Exact uncovered legacy branches are tracked in `.10`, not claimed as meeting the whole-file target. The pre-existing license_manager warning persists.
- Browser inspected real data read-only at 1440/390px. Preview move-button gesture and rank announcement verified; Save activated only on fixtures, then hot reload reset preview state. No live persistence gesture or logout. Physical drag, keyboard focus/Escape and final UX approval are still pending. Storybook duplicate page IDs discovered and fixed with isolated iframe variants.
- Issues: atomic command `.9`, live UI `.8`, validation `.7`, final human approval `.3`, consolidated E2E `.4`. Prototype acceptance/promotion authorization does **not** close `.3`. Existing E2E numeric-priority journey cannot receive selector-only repair; substantive update stays gated under `.4`.

### Historical prototype iterations

Latest approved correction (`zaq-tup.6`): extracted `DesignSystem.AccountMenu` from the actual BO avatar/name menu and reused it in BOLayout and PersonHeader. Caller-owned display name/routes/logout labels plus customizable IDs preserve all existing BO contracts. Preview passes fictional `@profile.person.full_name`; nil/blank safely displays Profile. Settings remains separate. Existing uncommitted work was preserved; no commit, push, worktree or other worker was used.

Latest validation supersedes counts below: `mix format`, `mix q` (1,251 files, no issues), `mix assets.build`, targeted tests, both targeted coverage commands and `git diff --check` passed. **2 properties, 34 tests, 0 failures**. ExCoveralls: AccountMenu 21/21, PersonHeader 9/9, ProfilePreviewLive 94/94 relevant lines; BOLayout 84.2% (legacy helpers). Existing `:license_manager` warning persists. JavaScript coverage is not included in these figures.

Signed-in browser: fictional name/avatar, menu contents, mutual Settings/account dismissal and outside dismissal verified. Account panel x=1184/w=224 on desktop 1440px and x=134/w=224 on mobile 390px. Reopen after resize if snapshots retain stale desktop geometry. Keyboard/Escape not exercised (OpenChamber exposes no keypress action); physical drag, long-content/scenario matrix, final UX approval `.3` and consolidated E2E `.4` remain pending. No real profile mutation or logout performed.

Branch `feat/people-profile-pages`, dirty working tree; no commits created. Existing shared stashes were listed, not changed or inspected. Beadwork epic `zaq-tup`: specification `.1` closed, prototype/verification `.2` in progress, shared-header iteration `.5` implemented, final human approval `.3` and consolidated E2E `.4` still gated. `.5` also blocks `.3` until closed.

At the latest source edit, `mix format`, `mix q`, `mix assets.build` and targeted coverage/test execution passed: 1 property + 31 tests, zero failures, including unchanged BO header and production profile regressions. Targeted coverage reported 100% for preview LiveView and PersonLayout, 84.6% for BOLayout and 6.7% for CoreComponents (legacy helpers not fully exercised; not a full-suite result). Only documentation changed afterward. A license_manager configuration warning appeared during tests; its cause was not investigated.

User signed in. Preview was inspected at desktop 1440px and mobile 390px. Verified theme dark/light changes, Settings/Profile menu contents, outside-click dismissal, mobile Settings bounds (left 118, width 240 within 390px viewport), name edit/cancel and move-button reorder/save. Physical dragging, keyboard focus/Escape, remaining browser scenarios and final human approval are still unverified; do not report them as passing.

## 3. Active files

| File | State | Role |
|---|---|---|
| `lib/zaq/accounts/people.ex` | Modified | Atomic channel-order operation and original ID/weight comparison under row locks |
| `lib/zaq/engine/people_auth_gateway.ex` | Modified | Confidential authenticated order command within existing profile authorization/transaction |
| `lib/zaq_web/live/people/profile_live.ex` | Modified | Full real-data promotion, parent-owned drafts, atomic Save and safe failure recovery |
| `lib/zaq_web/channel_order.ex` | Untracked | Shared pure reorder and accessible announcement helper |
| `lib/zaq_web/components/design_system/person_profile.ex` | Untracked | Production profile presentation and focus hook |
| `test/zaq/accounts/people_self_profile_test.exs` | Modified | Atomic validation, stale/rollback and permutation invariants |
| `test/zaq/accounts/people_test.exs` | Modified | Audit regression: fresh BO swap weights, cross-owner and missing/changed owner contracts |
| `test/zaq/accounts/people_channel_order_concurrency_test.exs` | Untracked | Real concurrent writers, late DB rollback and real web save failure/retry |
| `test/zaq/engine/people_profile_gateway_test.exs` | Modified | New command authority and confidential API/event checks |
| `test/zaq_web/live/people/profile_live_test.exs` | Modified | Production UI regression/security/persistence and draft-state scenarios |
| `test/zaq_web/channel_order_test.exs` | Untracked | Shared move invariants, boundaries and announcements |
| `storybook/components/design_system/person_{header,profile}.story.exs` | Untracked | Isolated production header/profile state variants |
| `DESIGN.md`, `docs/services/people-access.md` | Modified | Production inventory and atomic API/UI contract |
| `docs/ux/people-profile.md` | Untracked | Full UX spec, mapping, wireframes, gaps and validation notes |
| `lib/zaq_web/components/person_layout.ex` | Modified | Optional wide content; narrow default retained |
| `lib/zaq_web/router.ex` | Restored to baseline by cleanup | Retains live profile; staging route removed |
| `test/zaq_web/people_profile_routing_test.exs` | Untracked | Regression: retired preview URL is not routable |
| `lib/zaq_web/components/bo_layout.ex` | Modified | Uses extracted shared header; retains BO context/actions and existing IDs |
| `lib/zaq_web/components/core_components.ex` | Modified | Accessible labels on existing theme buttons |
| `assets/css/layout.css` | Modified | Responsive shared header and viewport-contained menu positioning |
| `assets/js/app.js` | Modified | Explicit production AccountDisclosure, PriorityDrag and ProfileFocus registrations |
| `lib/zaq_web/components/design_system/account_menu.ex` | Untracked | Shared BO avatar/name disclosure, caller-owned IDs/routes/name, generic hook |
| `test/zaq_web/components/design_system/account_menu_test.exs` | Untracked | Blank/Unicode/escaping property, ID/route/logout contracts, People composition |
| `test/zaq_web/components/bo_layout_test.exs` | Modified | Additional shared avatar/name and destination assertions; originals preserved |
| `lib/zaq_web/components/design_system/page_header.ex` | Untracked | Shared presentational header and heading with caller-owned slots |
| `lib/zaq_web/components/design_system/person_header.ex` | Untracked | ZAQ branding, shared theme control, Settings placeholder and People account menu |
| `test/zaq_web/components/design_system/page_header_test.exs` | Untracked | Heading slot contracts, menu chrome, named theme controls, People-only destinations |
| `lib/zaq_web/components/design_system/channel_priority_list.ex` | Untracked | Ordered provider rows, move buttons, colocated drag hook |
| `test/zaq_web/components/design_system/channel_priority_list_test.exs` | Untracked | Read/edit list and layout width tests |
| `docs/exec-plans/active/2026-09-15-handoff-people-profile.md` | Untracked | This continuation record; execution tracking remains in Beadwork |

## 4. Historical prototype changes (superseded by promotion and cleanup)

User chose existing fields/permissions, read-only team memberships and priority ordering with explicit Save/Cancel. User explicitly approved PersonLayout reuse after clarifying it is a page shell, not a list of people. Width is opt-in so login remains narrow.

Preview uses two desktop columns and a mobile stack; inline name editing; provider logos; move up/down alternatives plus desktop dragging. All identity data and simulated permissions come from fixtures. Scenario changes reset drafts, and preview saves change socket memory only. Real profile behavior, authentication modules, backend and Storybook remain untouched.

The additive preview route avoids replacing a working real profile with fictional identities. Atomic production reordering and concurrency handling remain a separate design/integration dependency. On review the user requested BO header reuse with title/description, theme, Settings/Profile controls and ZAQ logo, explicitly without a sidebar. User approved a Settings placeholder rather than BO admin links. BOLayout and People now compose the same PageHeader presentation; production profile/login retain the default PersonLayout header.

## 5. Historical failed attempts

- `bw list --search` was unsupported; use `bw list --grep`.
- First test invocation timed out at 20 seconds during test database migration/startup; later invocations with a longer timeout passed.
- Initial property generator used `uniq_list_of(positive_integer())`, whose small generation sizes exhausted unique values. Replaced with the bounded wide domain `integer(1..100_000)`; invariant assertions retained.
- First `mix q` found two nested-module alias suggestions in the new LiveView test; added the alias and reran successfully.
- Browser preview redirected to sign-in; no authentication bypass attempted. Automated LiveView tests exercised the protected route with genuine test sessions instead.
- After user sign-in, browser exposed unknown colocated hooks: main app uses explicit People opt-ins rather than spreading the hook registry. Registered the three specific prototype hooks; do not spread all hooks.
- One new assertion assumed Floki was installed. Replaced with LiveView selectors enforcing exactly one h1, keeping the assertion's intent.
- Review found Settings could extend left of a narrow viewport. Anchored dropdowns to the account nav rather than each disclosure. Browser then exposed transparent card-only chrome; composed existing raised/border classes and verified actual computed background and bounds.
- OpenChamber screenshot capture returned no image. Used snapshots and computed-style inspection; transient hot reload/shared-browser navigation also required reopening/resizing before confirming bounds.

## 6. Next step

**Current next step:** review the implemented `/people/profile` and record final UX/UI approval in `.3`; then author the consolidated E2E `.4`. Finish pending keyboard/drag checks against production UI with dedicated test identities when mutations are needed. The fixture preview is removed. Inspect `.12` for cleanup validation and `.10` for legacy coverage follow-up. No commit/push/new worktree was created.

The following earlier steps describe the pre-promotion handoff and are superseded:

1. **Blocked on user:** Review the corrected shared avatar/name account trigger at `http://localhost:4010/people/profile/preview` (fictional Alex Morgan). `.6` completes this approved correction; final feature UX approval remains `.3`, blocked by remaining `.2` work. Approve or provide the next iteration feedback.
2. **Ready:** Complete remaining browser checks (physical drag, keyboard focus/Escape, scenario matrix) under `zaq-tup.2`. Fix issues within fixture/UI scope and rerun `mix format`, `mix q`, affected tests and assets build. Include unchanged `test/zaq_web/live/people/profile_live_test.exs` and `test/zaq_web/components/bo_layout_test.exs`. Full legacy BOLayout/CoreComponents coverage remains a documented hardening follow-up.
3. **Optional:** Add explicit unauthenticated/expired-session preview-route regression assertions; existing new tests always use a valid session.
4. **Blocked on human approval:** `/design` hardening and separately scoped production save-order contract/integration. Keep final UX gate/E2E issues open; prototype acceptance is not final E2E approval.

Do not replace production data with fixtures, bypass auth, author new/substantially rewritten E2E journeys before final approval, weaken existing assertions to hide regressions, or commit/push without the user's request. The profile-boundary persistence extension described above was explicitly authorized.
