# Canonical assistant identity — branch review

- Branch: `fix/zaq-cbc-assistant-identity`
- Reviewed revision: `372c85892`; baseline: `049efee8c`
- PR: not opened; no remote review posted or push authorized by this report.
- Issue context: Beadwork `zaq-cbc`, implementation/approval comments `.1`–`.14`, and separate validation blocker `zaq-elu.1`.
- Scope follows the user's evidence-first correction: no demonstrated automatic differing-content double-finalization path; no generalized replay/crash protocol requested. Existing finalization idempotency is preserved.

## A — Inline review comments

### `lib/zaq_web/live/bo/communication/chat_live.ex:592`

**[medium] R1 — Presentation still treats reservation as persisted identity for suppressed output**

`db_id: if(error, do: nil, else: assistant_id)` assumes every non-error reserved answer was persisted. An existing reachable path disproves that: `Executor.handle_stream_error/7` → `suppressed_stream_error_result/2` returns `error: false, suppressed: true` after streamed content; Engine `failed_execution?/1` finalizes this without an assistant Message. Agent now explicitly retains `persisted_assistant_message_id: nil`, but WebBridge's final payload allowlists drop that evidence, and BO assigns the reserved UUID as its rating target. The widget final payload similarly places the reservation in its existing persisted-answer reference field, which pinned `Chat.retain_refs/2` retains as a saved-answer association.

Reproduction on the reviewed revision: invoke the actual public `ChatLive.handle_info/2` response entry with an ordinary pending socket and a `message_complete` payload containing `error: false, suppressed: true, assistant_message_id: <reserved UUID>, persisted_assistant_message_id: nil`. The resulting row has `db_id: <reserved UUID>` despite explicit absence of persistence. This consumer reproduction is supported by the actual Executor → Engine → Agent path above; it is not evidence about repeated finalization or a production incident.

Carry the existing optional persisted-answer evidence through presentation projection. When Engine explicitly returns nil, BO must have no persisted rating target; the widget's existing persisted-answer association field must not receive a reservation. Keep canonical envelope identity separate, preserve legacy events without the new evidence, and add suppressed/no-answer projection regressions. Do not redesign suppression text, error labels, terminal responses or replay behavior to fix this association bug.

## B — General PR conversation comments

No additional independent code findings. `zaq-elu.1` remains a separately tracked validation blocker, not a defect attributed to this increment or a waived test failure.

## C — Final recap

**Verdict: request changes — R1 remains open.**

The implementation addresses the audited live/final/history identity fragmentation using existing Engine lifecycle and transport boundaries. Root capability/owner/admission checks, root-only immutable reservation, successful Message UUID reuse, rollback, queued/recovered identity and opaque provider handles have focused regression protection. No unused generalized DTO remains. One persistence-versus-reservation distinction is still lost at the presentation boundary.

### Findings summary

- High: 0; medium: 1; low: 0.
- Inline comments: 1; general code findings: 0.
- No external review comments posted.

### Coverage and limitations

- Inventory: 34 changed files, including six owning guides, Engine/Agent/Channels/BO production changes, migration and focused tests/support.
- Review examined changed production paths and related untouched finalization, suppression, provider-edit and pinned-widget consumer seams; inspected focused regression assertions and recorded issue evidence. This is a branch/self-review, not independent human PR approval.
- Checked Action reuse: existing reservation/finalization/dispatch/history operations are extended, presentation remains local-only, and no automatic agent-tool exposure or duplicate operation framework is introduced.
- Checked local style, documentation, duplication and performance: no separate actionable finding; new database operations are bounded per request/root rather than unbounded render queries. Reused existing ChatLive reducer helpers instead of introducing a component redesign.
- User explicitly exempted manual UX approval and mandatory new E2E authoring, not execution: unchanged `webbridge_chat.spec.js` passed all 9 cases across Chromium/Firefox/WebKit; retries remained zero. `mix q` passed on the reviewed revision.
- Previous scoped matrix: 17 doctests, 81 properties, 2,582 tests; actual pinned widget consumer smoke: 4 tests. These results predate any R1 repair and must not be presented as validating that repair.
- Full-suite/coverage/final `mix precommit` have not passed. Three unrelated disk subset failures are tracked in `zaq-elu.1`; do not alter those fixtures, clear persistent rows, skip assertions or infer a waiver.
- Review approval, coverage handoff, final validation and landing authorization remain outstanding. No PR/push/merge performed.

### Token usage

Review-stage estimate: approximately 19,000 input tokens and 1,100 report/output tokens, approximately 20,100 total. Exact per-stage runtime token metrics are unavailable; this is not a billing measurement.
