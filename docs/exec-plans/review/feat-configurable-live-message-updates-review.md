# Configurable streamed-message updates — implementation review

- Branch: `feat/configurable-live-message-updates`
- PR: not created; review covers the current uncommitted implementation.
- Requirements: Beadwork `zaq-pta`, including the three-trigger contract and the user's unified-save iteration `zaq-pta.16`.
- Completed UX: renewed approval recorded in `zaq-pta.11`, “Approve unified-save UX for E2E refresh”, without conditions.
- Independent follow-up: GitHub #908 concerns existing status messages and is not a dependency.
- Review date: 2026-11-02; supersedes the earlier separate-save review.

## A. Inline review comments

No outstanding actionable findings.

## B. General PR conversation comments

No outstanding actionable findings. This is an agent self-review, not final human approval or authorization to commit, push, or merge.

## C. Final recap

**Verdict: approve for coverage validation.**

The implementation matches the revised contract: per-connector answer/reasoning/tool publication eligibility in the existing reducer; one optional shared event-driven interval; unchanged internal text batching; independent progress/status behavior; and canonical tool/trace/final delivery regardless of display preferences. No timer, queue, publisher process, configurable buffer, per-type interval, or snapshot filtering was added.

The updated modal uses one form and Save/Update action for ordinary fields and streamed preferences. Cancel discards all drafts. The frequency-off helper accurately distinguishes removal of time limiting from internal batching.

### Findings summary

- High: 0; medium: 0; low: 0.
- Inline comments: 0; general actionable comments: 0.
- Coverage is blocked by the fresh-report timeout in `zaq-pta.14`. No stale report or `mix coverup` result is accepted. Final `mix precommit` and human landing approval remain pending.

### Review coverage

Reviewed the feature's policy contract, Engine Action/API/resolution, ChannelConfig write preservation, Executor/reducer, shared form fields, native/widget modal integration, service contracts, and regression/E2E coverage. Followed seams into Status, ConnectorLifecycle, WidgetConnectorSettings, BOActor, ServerManager, Agent API finalization, and Conversations.

Checked:

- Closed JSON schema; absent versus malformed policy; explicit false values; known HTML normalization; unknown fields remain invalid. UI strips only known LiveView usage markers.
- Confidential management events, current BO authentication, identified runtime reads, exact connector scope and secret-free projections.
- Grouped native edits require a current lifecycle revision and execute ordinary changes plus the existing policy save in one transaction. The native operation rejects widgets rather than bypassing widget-specific validation.
- Widget saves extend the existing configuration transaction and reuse the same policy operation; invalid policy rolls back ordinary/routing writes. No circular dependency or second policy validator was introduced.
- Ordinary stale writers still preserve the current managed subtree. Unchanged absent preferences remain absent; policy-only saves retain the existing ciphertext-preservation regression. Ordinary edits retain ChannelConfig's existing loaded-token re-encryption semantics without changing the resolved credential.
- One reducer clock, no forced terminal/segment/settlement publication, unchanged status paths, complete canonical evidence, public projection reuse, stable identity and buffered-versus-published answer error handling.
- One shared stateless form fragment, no nested/independent policy form, no separate policy save or obsolete parent revision notifications. Parent drafts preserve disabled preferences and survive validation errors; Cancel and reload restore persisted values.
- Existing behavior changes are covered by explicit user approvals. The earlier intermediate-display lifecycle fixtures remain limited to their approved call sites. Persistence assertions synchronize on the existing consumer process rather than sleeps or database polling.
- Action reuse: extend existing Engine management/configuration operations, keep the policy owner authoritative, and expose no new agent tools. New BO writes use Engine events; unrelated create/data-source CRUD remains unchanged.
- No new dependencies, remote assets, unrelated runtime behavior changes, debug code, or unnecessary publisher abstractions.

Validation after the unified-save iteration:

- `mix q`: passed.
- 191 affected tests: passed (one property).
- 33 actual-widget lifecycle browser cases: passed.
- 18 existing channel/chat journeys across Chromium, Firefox and WebKit: passed.
- Six refreshed preference journeys across the same browsers: passed, including one-save persistence, Cancel, reload, connector isolation, disabled preference retention and helper text.
- Real native/widget desktop and widget mobile UI inspected; one form per modal, no separate save button or browser page errors.
- `git diff --check`: passed.

### Token usage

Review-specific runtime token metrics are unavailable. Approximate review input: 20,000 tokens including inherited implementation context; output: 1,000 tokens; total: 21,000 tokens. These are estimates, not billing metrics.
