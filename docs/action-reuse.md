# Action Reuse Gate

This is the canonical discovery and decision procedure for reusable ZAQ operations.
Apply it before planning every task, before implementing each step, and during review.
The goal is one operation implementation composable from code, agent tools, and
workflow steps where appropriate—not an Action wrapper around every function.

## 1. Assess applicability

List the executable operations the task adds, changes, or orchestrates (for example,
notifying people, updating routing rules, or transforming records). Bug fixes and
refactors must evaluate the affected operations too; this is not feature-only.
For documentation, styling, or other work with no executable operation changes,
record `Action reuse: not applicable — <reason>` rather than inventing Actions.
For a simple task, put the assessment in its issue; for planned work, in each step.

## 2. Discover before designing

Search by intent and domain, not just the proposed function name. Inspect candidates'
`@moduledoc`, input/output schemas, implementation, relevant tests, and callers to
establish semantics, authorization, side effects, execution requirements, and ownership.
Read the relevant service documentation. A roadmap does not replace this audit.

| Source of truth | What it establishes |
| --- | --- |
| `lib/zaq/agent/tools/registry.ex` (`Zaq.Agent.Tools.Registry`) | Stable keys and explicitly allowlisted agent tools; not an exhaustive Action catalog |
| `lib/zaq/agent/tools/` and Action declarations elsewhere in `lib/zaq/` | Existing operations, including Actions not exposed to agents; search `use Jido.Action` and `use Zaq.Engine.Workflows.Action` |
| Owning domain's public context/service APIs and Events helpers | Existing business logic and supported service boundaries that Actions should reuse |
| `lib/zaq/engine/workflows/action.ex` and `lib/zaq/engine/workflows/steps/` | Workflow contract and specialized infrastructure Steps |
| `docs/services/agent.md` and `docs/services/workflows.md` | Runtime tool selection, execution, and workflow lifecycle |

Do not maintain a second hardcoded catalog. Registry membership alone does not prove
workflow eligibility; a tools-directory module may be a build-time helper rather
than an executable node. If discovery cannot be completed, record the blocker—do
not assert that no reusable operation exists.

## 3. Record a decision for each operation

Choose in this order:

1. **Reuse:** call the existing Action through the appropriate execution boundary
   when it covers the operation. Do not copy its validation or side-effect flow.
2. **Extend:** add a cohesive, backward-compatible capability to the existing
   Action/domain implementation, preserving existing consumers and defaults.
3. **New Action:** when an essential operation is missing and has a meaningful,
   independently composable contract, propose a focused Action before writing a
   feature-specific function or flow. Existing domain logic stays authoritative;
   delegate to it rather than moving or duplicating it just to create an Action.
4. **Local-only:** retain a private helper or domain API when it is an implementation
   detail, has no meaningful standalone contract, or Action execution would violate
   ownership, lifecycle, or security constraints. Explain why reuse, extension, and
   a new Action are inappropriate. A single current consumer is not by itself a
   reason to reject a genuinely composable operation.

Each operation's `Action reuse assessment` must contain:

- **Operation and evidence:** candidate module paths/APIs and searches performed,
  including concrete semantic mismatches when rejecting candidates.
- **Decision and rationale:** reuse / extend / new Action / local-only; owning module
  and why its responsibility fits. Record `not applicable` with a reason when no
  operations are affected.
- **Contract:** inputs, outputs, errors, actor/permission context, side effects,
  retry/idempotency expectations, and runtime dependencies where relevant.
- **Consumers and execution:** intended code, agent-tool, and workflow use; which
  are in scope, deferred, or inappropriate, and the supported invocation boundary.
- **Verification:** existing tests to preserve and contract, failure, permission,
  consumer-integration, and relevant property tests to add. Tests must demonstrate
  consumers share the implementation rather than parallel copies of the operation.

Missing essential operations must have a proposed Action issue in Beadwork with
this contract and rationale. Link it as a prerequisite to consuming implementation
steps: `Action implementation → consumer integration`. Do not bury it in a generic
feature-helper step. Escalate architectural/product/security decisions for human
approval under `docs/WORKFLOW_AGENT.md`; unknown scope is not permission to build.

## 4. Preserve execution and security boundaries

- For programmatic Action execution, use the established validated execution path
  (for example, `Jido.Exec.run/3`) and its expected parameters/context. Calling
  `run/2` directly is not equivalent: it can bypass validation and execution behavior.
- Within workflows, preserve the engine/StepRunner lifecycle and auditing; do not
  replace a workflow step with an ad-hoc direct call. Workflow Actions must satisfy
  `Zaq.Engine.Workflows.Action`: non-empty input and output schemas and the required
  hooks. The engine does not itself invoke `on_success/2` or `on_failure/2`.
- Cross-service BO calls still go through the appropriate Events helpers and
  NodeRouter. Action reuse is not permission to call remote modules directly or to
  introduce a domain → Action → same-domain recursion.
- Preserve trusted actor context, authorization, and explicit permission opt-ins.
  Never infer elevated access from `person_id: nil` or trust user-supplied actor IDs.
- Reusability does not imply agent exposure. Add a Registry entry only when agent
  use is intended and its input surface, permissions, and effects are safe; preserve
  existing tool-selection/enablement controls. Workflow reuse does not require an
  agent-tool key. Do not expose internal helpers just to make them discoverable.

Examples to inspect, not copy: `Zaq.Agent.Tools.General.EncodeJson` supplies a
shared transformation; `Zaq.Agent.Tools.Accounts.NotifyUsers` delegates notification
delivery through an Engine event. Their source and tests, not this guide, define
their current contracts.

## 5. Recheck during implementation and review

Before coding each step, confirm the recorded candidates/contracts still apply.
If scope or evidence changes, update the assessment and prerequisite issues before
adding new operation logic. Do not implement a local fallback merely because an
Action is missing or difficult to call; resolve the boundary or document a justified
local-only decision first.

Reviewers must inspect the assessment and relevant existing implementations, not
only the changed files. Missing assessment, unjustified parallel operation logic,
an untracked missing essential Action, unsafe exposure, or bypassed execution and
permission boundaries must be resolved before approval. Cite concrete candidates
and mismatches; do not demand speculative abstractions or unrelated migrations.
