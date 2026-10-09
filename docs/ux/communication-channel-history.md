# PR A — Communication channel history: UX plan for first review

**Status:** Historical first-review UX proposal. The fixture-only prototype was replaced by database-backed BO list/detail, manual grants, supported Mattermost refresh, confirmed outbound history and restricted legacy snapshots on the uncommitted PR A branch. The fixture scenarios below are historical, not claims that all providers expose these capabilities. Final UX approval and new-feature E2E are still pending. Source brief: `zaq-emb.27`, `zaq-emb.4`, `zaq-emb.6`, `zaq-emb.10`, `zaq-emb.15` and issue #768.

## Current manual QA handoff (not an E2E approval)

Use the branch-isolated development database and start `PORT=4010 mix phx.server`; sign in as a current BO super-admin and open `/bo/channels/history`. The page reads real persisted transcripts through the Engine, with next/previous pages of 50 and a page-local filter. Open a Direct/Shared room or its separate Shared thread, read bounded messages, add/revoke a manual Person grant, and verify the source labels and independent provider grant survive manual revocation. On a linked, enabled Mattermost Shared room with a 26-character provider room ID, **Refresh Mattermost membership** reconciles only after all provider pages succeed; with no real connector the action reports failure and leaves access unchanged. Replicated email copies have message-local recipient visibility and no grant editor. Restricted legacy rows preserve original message IDs and private references but cannot be granted as fresh history. Unknown provider room kinds or unsupported providers do not show a refresh control.

The isolated dev database may contain no channel transcripts until a real connector receives messages; an empty screen is not a fixture. No outbound reply is shown as delivered solely because the Agent persisted an answer. A successful provider send followed by history-storage failure remains a successful delivery with `history_capture: :unavailable` for diagnosis; it does not claim durable history. Do not author PR A feature E2E until the reviewer explicitly approves the live UX in `zaq-emb.12`. This handoff does not claim PR review, coverage or final validation is complete.

### Manual-QA iteration: threads and display

The channel list now groups child transcripts behind a clickable thread count.
The channel-scoped thread list uses root-author initials and a trimmed root-message
preview. Thread detail displays the root above paginated replies. Stored roots are
resolved from the exact parent placement; missing Mattermost roots are read via a
confidential current-super-admin Channels operation that verifies post and room IDs.
This fallback is display-only and does not admit an agent run or duplicate canonical
messages. Unavailable roots are explicitly labeled. The last three distinct People,
ordered by latest participation, and an additional-participant count appear on list
rows. Channel summaries include their child threads. `PersonAvatar.avatar/1` supplies
stable Person-ID-derived colors wherever reused; unresolved identities use a neutral
fallback identity. User bubbles retain copy but no message-information control.

The six Mattermost Shared scenarios now have transport-mocked integration coverage
through the real adapter, Engine routing, agent execution and canonical storage:
channel ± mention, bot-authored root ± mention, and human-authored root ± mention.
All inputs persist. Channel nonmentions and human-root nonmentions remain silent;
the other four answer. Each case also replays its input to check stable message
identity and no duplicate response. Thread-first capture and identical provider
IDs on separate connectors are covered. The original four thread failures came
from validating parent-dependent facts before resolving the parent; capture now
validates coordinates first and validates resolved scope within the transaction.

The current UI uses locally bundled provider icons and known room names (connector
name when no room name is stored), with connector context below each list row.
`ChatMessage` renders People on the left with round initials and assistants on the
right with the ZAQ icon. Both history views use `ConversationDetail.message_timeline/1`
for width, spacing and timezone-aware date separators. Footer alignment follows
the bubble side. Copy, response feedback and message-info controls reuse the chat
components. Saved feedback survives reload. Message information is a separate
confidential, current-super-admin operation scoped to the selected transcript;
private execution data is not added to the shared-history or list projection.
The provider icon, room name and context live in the BO page header. Its sharing
action opens current access in a modal, including
the existing manual grants and supported membership refresh. Message pagination
now advances by transcript position instead of repeating the first page.
Lists use the standard table without a surrounding card or duplicate heading.
Whole-row navigation opens the transcript; the nested thread-count link retains
its independent destination. All parent navigation uses the existing page breadcrumb:
Channel history → channel → Threads → root-message preview, shortened appropriately
for channel detail and the threads list. Empty thread pages retain Engine-validated
parent context. Standalone back buttons and the generic Transcript crumb are removed.
The shared timeline owns its outer layout and full-width, capped inner container,
so short messages cannot shrink the transcript when hosted in a flex column.

Review these interactions with real connector data after signing in. The browser
session available to the assistant redirects to BO login, so authenticated visual
approval remains pending. The historical proposal below predates this iteration;
its sidebar access panel and staging timeline are superseded by these changes.

## Product translation

- **JTBD:** An authorized operator needs to inspect captured channel conversations, know who can read them, and understand when provider membership is unsupported or stale without causing a response or widening a past message's audience.
- **Primary users:** BO communication-channel administrators; People can read only their own authorized transcript through the separate authenticated People domain boundary. This first BO review does not add a People portal route.
- **Concepts:** connector → room/account → transcript (root or thread) → message; provider-derived and independent manual Person grants; email has per-message recipient-owned copies.
- **In scope:** channel history list/detail, thread navigation, bounded transcript messages, access state and provider/manual grant distinction, refresh capability feedback, email per-message audience, legacy-history explanation. Nonmentions are retained silently. All prototype data is static.
- **Out of scope:** PR B agent context refresh or delivery status; group/team/public read grants; Bcc inferred from `Delivered-To`; moving People UI outside Communication Channels; live provider integration in the prototype; creating a new E2E journey before human approval.
- **Success:** An operator can tell which history belongs to which connector/room/thread, whether a Person has current access, why older mail is not exposed to a newly added recipient, and whether a membership refresh can safely revoke access.
- **Risks/questions:** Only confirmed supported providers should show refresh. No partial membership result may look complete. Legacy history lacking per-message author or account provenance must remain marked restricted; do not offer a misleading “backfill everyone” control. Product review should confirm labels “provider access”, “manual access”, “stale/unsupported”, and whether a root with no messages should remain visible when a thread arrives first.

## Information architecture

- Within existing Communication Channels: `/bo/channels/history` (page title **Channel history**, current path same), `/bo/channels/history/:transcript_id` (page title **Channel transcript**, current path `/bo/channels/history`). Both use `BOLayout.bo_layout`. A link under the existing Communication section is the entry; room rows and breadcrumbs provide deep links. Do not add a People or data-source sidebar section.
- Transcript filters are connector and strategy; a thread is nested under its room. Email rows identify account/folder and per-message recipient ownership rather than claiming that a mailbox folder proves delivery.
- Prototype fixtures demonstrate an active room, a thread, two email recipients with different historical visibility, a revoked provider grant alongside a surviving manual grant, restricted legacy history, an unsupported refresh, an empty connector and a refresh error.

## Flows

### Inspect captured history
Actor: BO communication administrator. Trigger: Channel history from Communication navigation. Goal: understand an authorized room without causing a bot response.
1. List → choose connector/room → transcript detail.
2. Detail → follow a thread → return to room. Root messages and thread messages remain separate; sibling messages are not merged.
3. Review the access summary and message timestamps/attachments; execution-private traces and secrets are never presented as shared history.
Alternate: email opens recipient-specific visibility, with later-added recipients shown only for later messages.
Failures: missing transcript, disabled connector, empty history and unavailable provider evidence show explicit explanations, not fake “delivered” claims.

### Inspect or refresh access
Actor: BO administrator. Trigger: access panel on transcript detail. Goal: distinguish independent manual grants from provider-derived access.
1. Inspect Person rows with separate provider/manual source labels.
2. For a supported connector, request complete provider refresh; show processing, success or failure without changing manual access.
3. On removal, provider access disappears immediately; if manual access remains, the Person remains allowed with a manual label.
Alternate: unsupported/stale/partial provider result shows no revocation and explains why refresh is unavailable/incomplete.
Failure: permission denied uses an explicit no-access state; no action controls are available to a read-only viewer.

## Screen: Channel history list

**Route:** `/bo/channels/history` · **Entry:** Communication nav · **Purpose:** locate a bounded transcript without mixing connectors or threads.

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Channel history                            [scope/capability hint] │
├─────────────────────────────────────────────────────────────────────┤
│ Connector [select]    Strategy [select]      [Search]              │
├─────────────────────────────────────────────────────────────────────┤
│ Room/account │ Strategy │ Latest activity │ Access state │ Open   │
│  ↳ thread (nested, separate transcript)                            │
├─────────────────────────────────────────────────────────────────────┤
│ Empty / unsupported / error explanation                  [paging]  │
└─────────────────────────────────────────────────────────────────────┘
```

| Block | Content / interaction |
|---|---|
| Header | “Channel history”; secondary explanation: capture does not send a reply. |
| Filters | Connector, strategy and text search apply to the fixture list; clear filters returns to all. |
| Rows | Connector and room or account, thread marker, latest message, status, link to detail. Email labels per-message visibility, not implicit thread sharing. |
| States | Loading indicates read in progress; empty distinguishes no captured messages from filtered-out rows; error is retryable; denied displays no transcript data; disabled connector can still show previously authorized history. |

Accessibility: single H1, labeled controls, table headers, text alongside statuses, keyboard-operable links. Never reveal hidden recipients in list labels.

## Screen: Channel transcript detail

**Route:** `/bo/channels/history/:transcript_id` · **Entry:** list row or deep link · **Purpose:** inspect scoped messages and access with no accidental answer action.

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Breadcrumb: Channel history / Room / Thread                         │
│ Title · connector · strategy · scope                   [back]       │
├────────────────────────────────────┬────────────────────────────────┤
│ Bounded message timeline           │ Access & membership            │
│ [author, time, role, attachment]   │ Provider grants / Manual       │
│ [content; no private trace]        │ Refresh capability / state     │
│ [older / newer]                    │ Recipient visibility (email)   │
└────────────────────────────────────┴────────────────────────────────┘
```

| Block | Content / interaction |
|---|---|
| Breadcrumb | Back to list; room/thread hierarchy never includes sibling message content. |
| Timeline | Fixed-size page; role, author, time, body and safe attachment descriptor. “Nonmention — stored without reply” is a fixture note, not a claim of delivery. |
| Access panel | Current Person grants grouped by source; manual and provider may coexist. Revocation leaves the manual source intact. Email ownership is message-specific. |
| Refresh panel | Supported/unsupported/stale states; only a complete trusted refresh may remove provider access. Prototype controls change fixture state only. |
| States | Empty root with thread link; loading; inaccessible/missing same non-disclosing result; source error; restricted legacy transcript; disconnected connector with prior history readable. |

Accessibility: H1 followed by H2 for Messages and Access; status changes announced as text, pagination buttons labeled, no color-only permission semantics. Exclude raw trace, model prompts, secrets and inferred Bcc.

## Component mapping (§5)

| UX need | Existing module / function | Gap? |
|---|---|---|
| Shell + flash | `ZaqWeb.Components.BOLayout.bo_layout/1` | — |
| Page heading + breadcrumb | `DesignSystem.PageHeader.page_header/1`, `DesignSystem.Breadcrumb.page_breadcrumb/1` | — |
| Scope tabs, if used | `DesignSystem.TabNav.tab_nav/1` | — |
| Filters | `ZaqWeb.Select.select/1`, `DesignSystem.Input.input/1` | — |
| List and membership rows | `DesignSystem.Table.table/1` and row/cell helpers | — |
| Timeline/info panels | `DesignSystem.CardShell.card_shell/1` | [GAP] `DesignSystem.ChannelMessageTimeline.channel_message_timeline/1` is staging-only; review its attachment treatment for production. |
| Capability/access labels | Text labels in `DesignSystem.Table.table/1` with `.zaq-pill`; connection-status badges are not permission badges. | — |
| Empty/error | `DesignSystem.EmptyState.empty_state/1`, `BOLayout` flash | — |
| Refresh and paging | `DesignSystem.Button.button/1` for demo paging; refresh is display-only until real provider evidence is integrated. | — |

### Form field mapping (§5b)

No grant-edit or write form is proposed for the first UX review. List filters are non-persisted view controls:

| Screen | Field | Control | Gap? |
|---|---|---|---|
| List | Connector | `ZaqWeb.Select.select/1` | — |
| List | Strategy | `ZaqWeb.Select.select/1` | — |
| List | Search | `DesignSystem.Input.input/1` | — |

## UX decisions

- Stay within Communication Channels; do not add a generic People history entry.
- Explain silent capture and distinguish execution/persistence from delivery; no reply button is implied by a stored message.
- Keep thread transcripts separate and access derived from the parent room resource, not visual sibling aggregation.
- Preserve two independent access labels when both manual and provider grants exist.
- Hide unsupported refresh rather than imply missing provider evidence means no members. Do not infer old email audience or hidden Bcc.

## UI Designer Brief

Build order: (1) list and explicit empty/unsupported states; (2) transcript/timeline with bounded paging; (3) access/refresh states; (4) email and restricted-legacy scenarios. Page shell is always `BOLayout.bo_layout`; use only local assets and `--zaq-*` tokens per `DESIGN.md`. Storybook follow-up: status source combinations, transcript timeline/attachment descriptor, and refresh states after a component extraction review. Visual decisions open: density of nested thread rows and relative weight of access versus timeline. Backend data wiring, provider membership IO, agent context consumption, and any new-feature E2E are out of scope for the fixture prototype.

### Prototype handoff

`/prototype` implements §5 and §5b on `/bo/channels/history` with static fixtures under Communication only. The `[GAP]` timeline is a staging DSM component for `/design` review. No `Repo`, `NodeRouter`, agent calls, private payloads or Storybook edits. Human reviews the staged route for **first UX confirmation**; this is not final approval to author E2E tests (`zaq-emb.12`).
