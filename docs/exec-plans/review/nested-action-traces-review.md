# Nested Action traces — branch code review

- Branch: `zaq-1dq/nested-action-traces`
- Reviewed implementation HEAD: `20b8ef51a`
- PR number/link: not opened; this is a local branch review, not a GitHub approval.
- Linked work: `zaq-1dq`, children `.1`–`.17`; related decisions in `zaq-vhs` and `zaq-zmu`.
- Reviewer: coding agent applying `pr-review` and `pr-review-agent`; automated self-review, not an independent human review.
- Coverage follow-up: the two test-only additions were reviewed and approved after
  fixture corrections; measurement and remaining defensive/legacy branches are
  recorded in [the coverage report](nested-action-traces-coverage.md).

## A — Inline review comments

None. No new actionable high-, medium-, or low-severity defect was established
in the reviewed implementation.

## B — General PR conversation comments

None requiring an implementation change in this review pass.

The following are already-recorded delivery constraints, not newly discovered
findings or implicit waivers:

- The existing throttled root-tool snapshot can lack a trailing publication when
  the stream becomes quiet. The user explicitly deferred this to `zaq-vhs`; the
  original continuity test is unchanged, and its known failure is not reported as
  passing. The new nested journey uses one native root rather than disguising or
  replacing that test.
- Local feature verification uses Jido AI fork revision `4cb999e1` via the user's
  uncommitted dependency selection. The committed GitHub dependency is not claimed
  to provide that prerequisite. Upstream contribution and the subsequently approved
  portable dependency switch remain separate delivery work.
- Coverage handoff subsequently completed as documented in the linked report;
  final `mix precommit` remains pending. This review does not grant final human
  landing approval or authorize a merge.

## C — Final recap

### Verdict

**Approve the reviewed local implementation for the coverage handoff.** This is
the branch code-review verdict only, subject to the explicit constraints above;
it is not a portable-release or merge-readiness verdict.

### Assessment

The implementation addresses the nested agent/workflow evidence requirements
without adding a second execution path, collector, acknowledgement protocol,
tracing wait budget, or model-visible child tool registry. `ActionContract`
retains Jido execution policy and the original return envelope while protecting
the observer boundary against callback failures. Child paths preserve opaque
native roots and use explicit ancestry rather than prefix inference.

Agent facts remain in the existing request reducer; public steps, status labels,
sources and model tool counts exclude diagnostic children. Workflow persistence
validates captured roots, appends under a row lock, deduplicates event IDs, and
broadcasts authoritative snapshots without changing business fields. LiveView
merges immutable evidence while rejecting delayed running-state regression for a
settled row. Shared presentation retains legacy entries and unresolved outcomes.

Capability redaction, artifact extraction order, original effects, authorized
history and artifact reads, and nil-identity permission defaults were checked
against the affected seams and regression evidence. The new browser test initially
used a non-admin fixture for private history; correcting that fixture and adding
a real role downgrade verified the intended public/private boundary without a
production permission change. A redundant click on the already-selected active
workflow step was a new-test interaction error, not a production rendering defect.

### Audit checklist

- **Reuse/boundaries:** extends `ActionContract`, native `Request.Stream`, existing
  reducer/persistence APIs and shared trace panel. Composed callers retain narrow
  context allowlists and execution options. No new Action prerequisite or tool
  exposure was identified. BO/domain reads continue through `NodeRouter`.
- **Duplication:** workflow generic/fork call sites share `step_action_traces`;
  no parallel tree store or engine dependency on the Agent reducer was introduced.
  The Storybook-only shell is explicitly contextual preview chrome, not a copy
  or replacement of the entire production step card.
- **Performance:** checked per-event row locking/JSON append, snapshot reload,
  trace grouping/traversal, duplicate handling and public projection. These follow
  the agreed synchronous workflow and nonblocking agent contracts; no additional
  collector or per-broadcast UI database lookup was introduced.
- **Style/documentation:** module responsibilities and callback lifetime are
  documented; additive migration is reversible and defaults historical rows to
  an empty event array. Production and preview CSS outputs are separate. The
  scoped dev-only iframe guard preserves upstream sizing without hiding errors.
- **Tests:** no existing assertions, retries, navigation waits or timeouts were
  weakened. The resumed-workflow test now drains its real task before sandbox
  teardown. Feature E2E was authored after the recorded human UX approval.

### Findings summary

- High: **0**; medium: **0**; low: **0**.
- Inline comments: **0**; general actionable comments: **0**.

### Review and validation coverage

- Read the epic and child acceptance/decision context, including relevant comments,
  the approved simplifications, the explicit `zaq-vhs` deferral, and Storybook repair
  evidence in `zaq-zmu`.
- Inspected the 51-file branch inventory, affected production diffs and nearby
  execution, persistence, authorization and UI definitions; reviewed the new browser
  fixtures/runner and relevant regression scenarios. Not a claim of exhaustive
  inspection of every pre-existing test body.
- Final issue-level verification at this HEAD: **444 focused checks passed**
  (**21 properties, 423 tests**); **3 real browser journeys passed** across Chromium,
  Firefox and WebKit; **13 JavaScript checks passed**; `mix q` and commit-hook `qf`
  passed.
- Existing full Playwright suite previously passed **582 tests, 3 pre-existing
  conditional skips**; the preview correction subsequently passed **108 existing
  Storybook checks**. These earlier results are not misrepresented as a new full
  suite run at this HEAD.
- Serena became unavailable during this session. Review used bounded source/diff
  reads and Context Mode rather than claiming semantic-tool coverage.

### Token usage

Rough review-pass estimate: **20,000 input tokens**, **1,400 output tokens**,
**21,400 total**. Actual per-review runtime token metrics are not exposed; these
estimates are not a measurement of the overall implementation conversation.

## Human-validation follow-up — failed Run Agent diagnostics

Julien's final validation exposed a real gap not covered by the initial review:
`RunAgent` discarded partial agent telemetry on an error response, StepRunner
persisted only the error, and the BO hid its agent panel for failed steps. The
reported run's stored reason was `agent_failed::provider_rate_limited`; preserving
diagnostics does not bypass that provider failure or recover already-lost data.

The `zaq-1dq.18` repair extends the existing `ExecutionFailureError` envelope with
an explicit generic `details.workflow_results` contract. RunAgent supplies only
its existing JSON-safe telemetry allowlist. Engine code treats that map as opaque
and stores it through `fail_step_run`'s optional results argument; it imports no
Agent implementation and does not forward closures across dispatch. Failed status,
public message, native identity, and retry/timeout policy remain intact; StepRunner
returns the supplied error unchanged. Diagnostic output is not cascaded, promoted to successful business
output, or printed in failure logs. Errors without observed telemetry retain the
old string shape. The UI correction reuses the existing panel and only removes its
success/waiting-only visibility guard, leaving business-output guards unchanged.

Self-review approves this repair for the renewed coverage handoff. A generic
confidentiality/cascade property and real Jido error roundtrip cover the transport;
real native integration covers success, rate limiting after nested work, and
pre-tool rate limiting. New LiveView cases prove failed/isolated-failure expansion
and reload. All **216 focused checks** pass (**6 properties, 210 tests**), as does
`mix q`. Julien subsequently approved the corrected workflow UI in the revalidation
form. Only then were the Run Agent browser cases authored; the expanded existing
journey passes in **Chromium, Firefox and WebKit** (**3 test journeys**), retaining
all prior chat/direct-Action checks, waits, timeouts and zero retries.

New fixture corrections were limited to supported Outgoing fields, existing
`failed_fatal` map semantics, dynamic helper dispatch to avoid compile warnings,
owned workflow-task teardown, and the existing native root row's label (known
success is asserted through the backend projection; nested rows retain explicit
outcome labels). No existing test assertions were weakened. User-owned dependency
and workflow fixture files remain outside this repair. Fresh coverage and final
`mix precommit` must be repeated; the earlier passing final gate is historical.
