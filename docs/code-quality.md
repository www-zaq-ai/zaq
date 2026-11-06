# Code Quality

## Write for Humans

Write code for the next maintainer, not only the compiler. Someone familiar with
the language should understand its intent without reconstructing hidden assumptions.
Prefer straightforward, idiomatic code over cleverness or terseness.

- Use domain language and intent-revealing names under the [naming conventions](conventions.md#naming).
  Make the operation and relevant distinctions clear at the call site.
- Keep each function focused on a recognizable task. Extract helpers when they name
  a meaningful step or isolate complexity, not merely to meet a line-count target.
- Make success and failure paths easy to follow. Limit nesting and name complex
  conditions when that clarifies their meaning. Choose pattern matching, `case`,
  `cond`, or `with` to suit the flow; do not force one construct everywhere.
  Pipelines should read as a clear sequence of transformations.
- Make units, identifiers, optional values, defaults, and side effects explicit
  where they affect understanding. Prefer named options or domain values over
  ambiguous boolean arguments. Name unexplained domain literals; ordinary literals
  whose meaning is clear in context do not require constants or module attributes.
- Keep related logic together and variables near their use. Avoid changing a
  variable's conceptual meaning or making readers traverse trivial wrappers to
  understand one operation. Preserve required architectural boundaries.
- Improve confusing names and structure before adding explanatory prose. Retain
  comments that explain real reasons or constraints under the [writing rules](documentation.md#writing-comments-and-documentation).

Review question: can the next maintainer explain what this code does, why each step
exists, and how it fails without unnecessary detective work?

Apply this standard within the requested change. Readability findings must identify
a concrete ambiguity or source of complexity and its consequence for understanding
or maintenance. Do not demand personal naming preferences, unrelated renaming, or
mechanical syntax changes. Respect [minimal change surface](#minimal-change-surface)
and the [function reuse decision](#function-reuse-decision).

## Minimal Change Surface

- Prefer the smallest coherent change that fully satisfies the request and preserves architectural boundaries. Minimize unnecessary scope, not merely changed lines or file count.
- Limit changes to the code, tests, configuration, and documentation needed for the requested outcome. Avoid unrelated cleanup, renaming, formatting churn, and speculative abstractions.
- Reuse established patterns and operations under the rules below. Minimality never justifies duplicated operations, bypassed boundaries, or omitted required validation.
- Broaden the change when correctness or existing contracts require it, and explain why. Record unrelated improvements as follow-up work rather than folding them into the change.

## Separation of Concerns & Architecture Boundaries

- Keep domain and business rules in `lib/zaq/` contexts/domain modules.
- LiveViews, controllers, plugs, and workers orchestrate and delegate — never own business logic.
- BO modules in `lib/zaq_web/` must not access persistence or integrations directly — call context APIs and use `NodeRouter.dispatch/1` with `%Zaq.Event{}` for cross-service boundaries.
- Treat context internals as private implementation details. Cross-context calls use public context functions, not internal helpers.
- Keep module responsibilities cohesive. If a module owns unrelated concerns (querying + formatting + transport), split it.
- For bridge/adapter domains, enforce: bridge orchestrates, adapter implements transport mechanics.
- Reject changes where bridges define adapter listener child specs directly; bridge must delegate runtime spec construction to adapter APIs.
- Reject adapter-specific sink callback names in bridge APIs; use standardized `from_listener/3` callback naming.

---

## DRY & Pattern Reuse

- Reuse existing Actions/tools, context APIs, query helpers, changeset patterns, and UI components before introducing new abstractions. Apply [the Action reuse gate](action-reuse.md) before planning, implementation, and approval.
- Apply a rule-of-three for incidental helper extraction once the pattern is stable; this never permits duplicating an existing operation or postponing evaluation of a missing essential composable Action.
- Require evidence-backed reuse / extend / new Action / local-only decisions (or justified not applicable). Reject unjustified parallel operation flows and untracked missing essential Actions; preserve validated execution, permission checks, NodeRouter boundaries, and deliberate agent-tool exposure.
- Prefer extending established project patterns instead of creating competing variants without a strong reason.
- Avoid catch-all utility modules. Helpers should be domain-scoped and intent-revealing.
- Prefer shared utility packages over hand-rolled helpers to keep invariants centralized.

### Function Reuse Decision

Apply this decision procedure when adding or adapting functions, including private
helpers. For executable operations, also apply the [Action reuse gate](action-reuse.md);
this procedure does not replace its ownership or execution constraints.

1. **Discover before adding.** Search by intent and domain; inspect candidate
   implementations, module responsibilities, contracts, relevant tests, and callers.
   Include external consumers and dynamic invocation where applicable; an empty
   reference search does not prove a public API has no consumers.
2. **Reuse as-is.** If an existing function satisfies the required semantics through
   a supported architectural boundary, call it rather than duplicating its logic.
3. **Prefer a backward-compatible extension.** When adjustment is needed, first
   evaluate a cohesive extension that preserves existing callers' behavior and
   defaults without editing them. Do not force compatibility through a confusing
   abstraction, caller-specific branches, or an accumulation of mode flags.
4. **Compare alternatives when extension requires caller changes or adds complexity.**
   Evaluate migrating callers, adding a focused function, and retaining the existing
   API as a delegating wrapper around shared implementation. A new entry point need
   not duplicate logic; share the common implementation where responsibilities align.
5. **Choose risk first, churn second.** Choose the lowest-risk coherent solution;
   when risk is comparable, choose the least code churn. Assess regression blast
   radius, contract and boundary changes, abstraction complexity, migration and
   rollback difficulty, and ongoing maintenance risk. Include affected callers,
   tests, documentation, migrations, and downstream consumers when estimating churn.
   Fewer changed lines today do not outweigh future divergence of fixes or checks.

Compatibility covers input acceptance, defaults, return shapes, errors, side effects,
authorization, ordering, and relevant performance characteristics—not just signatures.
Share domain meaning and invariants, not merely similar syntax: functions with
different responsibilities may appropriately remain separate. Do not expose private
internals or cross ownership boundaries just to eliminate similar-looking code.

Verify preserved behavior with existing regression coverage, adding focused cases
where needed, and verify the new capability. Follow the [testing handbook](testing-approach.md),
including approval for changes to existing test behavior.

For nontrivial choices, record the candidates, semantic fit or mismatch, affected
consumers, and risk/churn rationale in the existing issue or PR assessment. Reviewers
must apply this procedure to changed functions and cite concrete reusable functions
and contract evidence when requesting changes; do not demand speculative abstractions
or unrelated refactors. Keep evidence proportional to the change.

---

## Data Access & Side-Effect Boundaries

- Keep Ecto queries and persistence logic in context/domain modules — never in LiveViews, components, or templates.
- Keep HTTP/external calls in adapter/integration modules; depend on behaviours at domain boundaries.
- Preload associations when needed by rendering layers to prevent N+1 queries.
- Make Oban workers and external side-effect operations idempotent so retries are safe.
- Do not probe data shapes speculatively — validate at boundaries or rely on typed SDKs.

### BO LiveView Query Discipline

- `handle_event("validate", ...)` must run from assign state only; no DB reads in validation loops.
- Load reference datasets (credentials, static option lists, enums) once in `mount/3`; cache as both list and lookup map (`*_by_id`).
- Keep selected edit entities in assigns (`:selected_*`) and reuse them across validate/save flows instead of refetching by id.
- Context validation pipelines must resolve shared lookup dependencies once per operation and pass them through helper validations.
- New BO pages must include query-budget regression tests for hot interactions (row select, validate, save) using repo telemetry (`[:zaq, :repo, :query]`).

---

## Technical Debt Controls

- Any temporary shortcut must be marked with an inline comment — Credo blocks bare `TODO` tags, so use this format instead:
  ```elixir
  # Temporary: <why it's here now>. Move to <target module/function> once <condition>.
  # Tracked: <issue ID or URL>
  ```
- Remove dead code and stale branches when replacing behavior — do not keep inactive paths "just in case".
- If a change intentionally diverges from established patterns, document the rationale in the PR description.
- Track all known debt in `docs/exec-plans/tech-debt-tracker.md`.

---

## Linting & Enforcement

- Read and follow the [validation lifecycle](WORKFLOW_AGENT.md#phase-4--validate) for required commands, tests, failure handling and approval timing; do not maintain a separate gate here.
- `mix credo --strict` for code standards on bugfixes.
- During development, prioritize tests for critical behavior, failure paths, permissions, and regressions rather than a coverage ratio. Preserve async-friendly configuration/dependency injection and isolated state. Delegate numerical coverage targets to the post-review `coverage-upper` phase before merging.
- `.credo.exs` defines the enabled Credo checks, including `Credo.Check.Design.TagTODO`. Inspect that configuration and the relevant tests before claiming a rule is automatically enforced.
- Review the responsibility boundaries in [architecture](architecture.md#layered-domain-architecture); passing lint is not proof that every architectural boundary is respected.

---

## Quality Grades

Domain quality grades are tracked in `docs/QUALITY_SCORE.md`. Consult it to understand
the current state of each domain before making changes, and update it when the state changes.
