# Execution Plan — Failure-Routing Edges

> Status: ACTIVE · Created 2026-05-19 · Branch `feat/workflow-data-model`
> Strategy: follows `docs/exec-plans/PLAN_STRATEGY.md`. Tracked in this file (Beadwork intentionally **not** used per explicit instruction).

## Goal

Let workflow edges express failure routing: a DAG `A → B → C` where, if `B` fails,
execution routes to `D` instead of `C`. The `Step.Edge` data model gains an `on`
discriminator (`"success"` | `"failure"`) and a per-edge `recover` flag:

- `on: "failure", recover: true`  → catch-and-continue: `D` is a recovery path; if `D` succeeds the run ends **success**.
- `on: "failure", recover: false` → side-branch: `D` runs as compensation/notify; the run still ends **FAILED**.
- No `on: "failure"` edge from a failed node → **current behavior preserved**: the run hard-fails (no silent swallow).
- `ConditionNotMet` (condition-node raise/prune) is a **distinct** path and is *not* treated as a failure.

---

## Pre-Planning Infrastructure Audit (Mandatory)

Domain: `lib/zaq/engine/workflows/`. Findings from reading the relevant `@moduledoc`s and code:

| Concern | Existing home | Reuse decision |
|---|---|---|
| Edge data model | `Zaq.Engine.Workflows.Step.Edge` (`steps/edge.ex`) — `from`/`to` only | **Extend** the existing embedded schema. No new module. `@moduledoc` ("directed edge between two nodes") still accurate; will be amended. |
| DAG assembly | `Zaq.Engine.Workflows.DagBuilder` — assembles `Runic.Workflow` from `nodes`/`edges`; currently only **unconditional `Runic.Workflow.add(to:)`** + raise-based prune | **Extend** assembly; `@moduledoc` edge example/Node-types text must be updated. No parallel builder. |
| Step execution + StepRun cursor | `Zaq.Engine.Workflows.ActionWrapper` — `complete_step_run` on `{:ok}`, `fail_step_run` on `{:error}`/rescue, reraise on raise; `ConditionNotMet` → `skip_step_run` | **Extend** the `{:error,_}` / non-`ConditionNotMet` rescue branch only. `ConditionNotMet` path untouched. |
| Branching idiom today | Condition nodes (`Conditions.FieldComparison`) raise `ConditionNotMet`; Runic prunes downstream | Mirror this idiom for failure routing rather than inventing a parallel mechanism. |
| Run-final status | `Zaq.Engine.Workflows.WorkflowAgent.execute/2` — any propagated error → run FAILED (`workflow_agent.ex:59,67`) | **Extend** to honor a recovered failure. |
| Condition / skip marker | `Conditions.ConditionNotMet` | Untouched (reference only). |

**Key risk identified by the audit:** the engine has *no* mechanism to route on an
upstream node's success-vs-error outcome. Only raise-prune and unconditional
`add(to:)` exist. Whether Runic can do outcome-conditional routing natively is
unknown and **must be resolved in Step 1 before the dependent steps are designed
in detail.**

## Module Responsibility Confirmation

1. `Step.Edge` — owns edge shape/validation. `on`/`recover` are edge attributes → fits.
2. `DagBuilder` — owns steps→`Runic.Workflow` assembly. Wiring success/failure branches → fits.
3. `ActionWrapper` — owns per-step execution + StepRun cursor + outcome translation → fits.
4. `WorkflowAgent` — owns run lifecycle/final status → fits.
- No cross-cutting concern (credentials/URL/permissions) is pulled into a domain module.

## Security Checklist

**N/A** — no step touches permission filtering, `person_id`, `skip_permissions`,
or data-access scope. Confirmed no `person_id` path is introduced or altered.

## Test Strategy

Per `docs/testing-approach.md` and PLAN_STRATEGY Test Strategy: favor **integration
tests through real module boundaries** (DagBuilder → Runic → ActionWrapper →
WorkflowAgent → StepRun). No seams. Internal deps kept real.

## Mocking Plan

**N/A for the whole plan** — no external edge/third-party API is involved. Test
actions are in-repo (`test/support/workflow_test_actions.ex`). Keep all internal
primitives real.

## Coverage Policy

Every file added/modified must reach **≥ 95%**. Coverage verified in Step 6
before the plan closes; any shortfall documented in the Decisions Log + PR.

---

## Dependency Graph (DAG)

```
Step 1 (spike) ─┐
                ├─▶ Step 3 (DagBuilder) ─┐
Step 2 (schema)─┘                        ├─▶ Step 5 (run-status + e2e) ─▶ Step 6 (docs+coverage)
Step 1 ───────────▶ Step 4 (ActionWrapper)┘
```

- Roots ready at start: **Step 1**, **Step 2** (independent).
- Step 3 `depends_on` [1, 2]. Step 4 `depends_on` [1].
- Step 5 `depends_on` [3, 4] — convergence (diamond) is **required and justified**:
  3 (assembly-time) and 4 (run-time) are independent module changes sharing only
  the Step-1 routing contract; end-to-end behavior cannot be validated until both land.
- Step 6 `depends_on` [5]. No cycles.

---

## Step 1 — Runic outcome-routing spike + decision record

**1. Functional specifications + files**
Determine the mechanism by which a failed upstream node activates a `failure`
branch and suppresses the `success` branch. Two candidate designs:
- **(A) Native:** Runic supports conditional branch activation on producer outcome.
- **(B) Fallback (assumed if A unproven):** `ActionWrapper` converts a failure into
  a routable fact (e.g. `%{__outcome__: :error, reason: ..., recover: bool}`);
  `DagBuilder` wires `success`/`failure` edges as condition-guarded branches using
  the existing `ConditionNotMet`/`FieldComparison` raise-prune idiom.
- Files: spike characterization test only; **decision recorded in this file's
  Decisions Log**. No production code in this step.

**2. Tests to add before implementation**
- `test/zaq/engine/workflows/dag_builder_test.exs` — characterization test:
  `A → B(fails) → D` with a `failure` edge routes to `D` and does **not** run `C`,
  using the chosen mechanism. Written before the mechanism is committed.

**3. Branches/paths validated**
- B success → success edge taken, failure edge not taken.
- B `{:error,_}` → failure edge taken, success edge suppressed.
- B raises non-`ConditionNotMet` → same as `{:error,_}`.
- `ConditionNotMet` → existing prune path, unaffected.

**4. Mocking plan** — N/A.

**5. Docs to update** — Decisions Log entry in this plan recording chosen design
(A or B) and the routable-outcome contract shared by Steps 3 & 4.

---

## Step 2 — `Step.Edge` schema: `on` + `recover`

**1. Functional specifications + files**
- `lib/zaq/engine/workflows/steps/edge.ex`: add
  `field :on, :string, default: "success"` and
  `field :recover, :boolean, default: false`.
  Changeset: `cast` both; `validate_inclusion(:on, ~w(success failure))`;
  normalize `recover` to `false` when `on != "failure"` (recover only meaningful
  on failure edges). `from`/`to` remain required.
- `lib/zaq/engine/workflows/workflow.ex` — already `cast_embed(:edges)`; verify
  defaults round-trip through JSONB embed (no SQL migration: `embeds_many`).
- Amend `Step.Edge` `@moduledoc` to document `on`/`recover`.

**2. Tests to add before implementation**
- `test/zaq/engine/workflows/steps/edge_test.exs` (create if absent):
  default `on="success"`, `recover=false`; rejects `on` not in
  `success|failure`; `recover` forced false when `on="success"`; `from`/`to`
  still required.
- `test/zaq/engine/workflows/workflows_test.exs` — `Workflow.changeset`
  round-trips edges with `on`/`recover` through the embed.

**3. Branches/paths validated** — valid success edge; valid failure edge w/
recover true & false; invalid `on`; missing `from`/`to`; recover-with-success
normalized.

**4. Mocking plan** — N/A.

**5. Docs to update** — `docs/services/workflows.md` (edge format);
`Step.Edge`/`Workflow` `@moduledoc`.

---

## Step 3 — `DagBuilder`: wire success/failure branches

**1. Functional specifications + files** (`depends_on` 1, 2)
- `lib/zaq/engine/workflows/dag_builder.ex`: in `assemble/2` group a node's
  **outgoing** edges by `on`; wire `on:"failure"` targets via the Step-1
  mechanism distinct from `on:"success"` targets; thread `recover` into the
  wiring/wrapper params. Existing `validate_edges/2` extended so a `failure`
  edge's `to` is validated like any edge. Default (no `on`) → `success`
  (back-compat: existing workflows unchanged).
- Update `DagBuilder` `@moduledoc` "Expected input format" example + Node-types
  text to show an `on:"failure"` edge.

**2. Tests to add before implementation**
- `test/zaq/engine/workflows/dag_builder_test.exs`:
  - Regression: success-only DAG assembles unchanged.
  - `A→B→C` + `B→D (on:"failure")` builds; routing wired per Step 1.
  - `recover` value carried through.
  - Failure edge with unknown `to` → `{:error,{:unknown_node,_}}`.

**3. Branches/paths validated** — success-only (regression); mixed
success+failure out-edges; recover true/false carried; invalid failure target.

**4. Mocking plan** — N/A.

**5. Docs to update** — `DagBuilder` `@moduledoc`; `docs/services/workflows.md`
DAG-engine section.

---

## Step 4 — `ActionWrapper`: emit routable failure outcome + carry recover

**1. Functional specifications + files** (`depends_on` 1)
- `lib/zaq/engine/workflows/action_wrapper.ex`: in the `{:error, reason}` branch
  and the non-`ConditionNotMet` `rescue` branch, keep `fail_step_run` + logging,
  but emit the Step-1 routable outcome (instead of returning the bare
  `{:error,_}` fact / killing the run) so the failure branch activates and the
  success branch is suppressed; surface `recover`. `ConditionNotMet` →
  `skip_step_run` path **unchanged**. Update `@moduledoc` to describe the new
  outcome translation.

**2. Tests to add before implementation**
- `test/zaq/engine/workflows/action_wrapper_test.exs`:
  - `{:error,_}` from wrapped module → StepRun `failed`, routable failure
    outcome emitted, `recover` surfaced.
  - Raised non-`ConditionNotMet` → StepRun `failed`, same outcome, reraise
    semantics adjusted only as Step 1 dictates.
  - `ConditionNotMet` → still `skipped` (regression).
  - `{:ok, result}` / `{:ok, result, logs:}` → unchanged (regression).

**3. Branches/paths validated** — ok / ok+logs / error tuple / raise-other /
raise-`ConditionNotMet`.

**4. Mocking plan** — N/A (uses `test/support/workflow_test_actions.ex`).

**5. Docs to update** — `ActionWrapper` `@moduledoc`.

---

## Step 5 — Run-status integration + end-to-end recover semantics

**1. Functional specifications + files** (`depends_on` 3, 4)
- `lib/zaq/engine/workflows/workflow_agent.ex`: final run status honors recovered
  failure — run = **success** iff every taken `failure` edge has `recover:true`
  **and** its target succeeds; otherwise **FAILED**. No `failure` edge from a
  failed node → **FAILED** (unchanged). Update `execute/2` `@moduledoc`/`@spec`.
- Mixed-recover rule (documented default): if a failed node has multiple taken
  `failure` edges and any has `recover:false`, the run ends **FAILED**.

**2. Tests to add before implementation**
- `test/zaq/engine/workflows/workflow_agent_test.exs` — integration through real
  boundaries:
  - `A→B→C` all success → unchanged (regression).
  - `B` fails, `B→D (failure, recover:true)`, `D` ok → run **success**, `C`
    absent/skipped, StepRuns: B `failed`, D `completed`.
  - `B` fails, `B→D (failure, recover:false)` → run **FAILED**, D `completed`.
  - `B` fails, no failure edge → run **FAILED** (current behavior preserved).
  - `B` raises non-`ConditionNotMet` → routed identically to `{:error,_}`.
  - `ConditionNotMet` still `skipped`, run not failed (regression).
  - Mixed recover (one true, one false) → run **FAILED** (documents the rule).

**3. Branches/paths validated** — all rows above (success regression, recover
true, recover false, no-edge hard-fail, raise routing, ConditionNotMet
regression, mixed-recover).

**4. Mocking plan** — N/A.

**5. Docs to update** — `docs/services/workflows.md` run-lifecycle + new
"Failure-routing edges" section; `WorkflowAgent` `@moduledoc`.

---

## Step 6 — Docs, coverage, precommit (Definition of Done)

**1. Functional specifications + files** (`depends_on` 5)
- Finalize `docs/services/workflows.md` (failure-routing edges: schema, runtime,
  recover semantics, mixed-recover rule, back-compat note).
- Verify `@moduledoc`s updated: `Step.Edge`, `Workflow`, `DagBuilder`,
  `ActionWrapper`, `WorkflowAgent`.
- Run coverage; ensure every touched file ≥ 95%; run `mix precommit`.

**2. Tests to add before implementation** — none new; this step *validates*
coverage and gates DoD.

**3. Branches/paths validated** — coverage report inspected per touched file.

**4. Mocking plan** — N/A.

**5. Docs to update** — `docs/services/workflows.md`; this plan moved to
`docs/exec-plans/completed/` on close.

---

## Definition of Done

- [ ] Step-level functional specs written before implementation (this file).
- [ ] Step-level test definitions written before implementation (this file).
- [ ] Step 1 decision recorded in Decisions Log before Steps 3–4 implemented.
- [ ] All required tests implemented and passing.
- [ ] Coverage ≥ 95% for every touched file (else documented here + in PR).
- [ ] `mix precommit` passes.
- [ ] Back-compat verified: existing `success`-only workflows behave identically.

## Decisions Log

- 2026-05-19 — Failure-edge semantics: **per-edge `recover` flag** (chosen by
  user over catch-only / side-branch-only). `recover:true` = catch-and-continue;
  `recover:false` = compensation, run still FAILED.
- 2026-05-19 — Beadwork intentionally not used for this plan (explicit user
  instruction); planning tracked in this file instead.
- 2026-05-19 — **Routing mechanism: Approach B confirmed (routable fact +
  guarded branches).** Approach A (native Runic) is ruled out. Evidence from
  `JIDO_RUNIC_EVENT_FLOW.md` §5: `handle_failed_runnable` →
  `skip_downstream_subgraph/2` relabels **all** transitive `:flow` successors to
  `:upstream_failed` when a runnable fails — there is no hook to distinguish
  success vs failure branches. Returning `{:error, _}` from `ActionWrapper` would
  prune both the success branch and the intended failure branch.

### Step 1 — Full Approach B Contract

**`ActionWrapper` change (error path only, gated on `has_failure_edges`)**

- DagBuilder passes `has_failure_edges: true` in `wrapper_params` for any node
  that has at least one outgoing `on: "failure"` edge.
- When `has_failure_edges: true`:
  - `{:error, reason}` → `fail_step_run` + return
    `{:ok, %{__outcome__: :failure, reason: inspect(reason)}}` (no propagate).
  - Non-`ConditionNotMet` rescue → `fail_step_run` + return
    `{:ok, %{__outcome__: :failure, reason: Exception.message(e)}}` (no reraise).
  - `ConditionNotMet` rescue → **unchanged** (reraise; Runic prunes downstream).
- When `has_failure_edges` absent/false → **current behavior unchanged**.
  `{:error, _}` is returned as-is; non-`ConditionNotMet` raises reraise; Runic
  prunes all structural successors as before. Back-compat for existing workflows
  is automatic.

**`DagBuilder` change — synthetic `OutcomeGuard` injection**

For any source node S with at least one `on: "failure"` outgoing edge:

1. For each `on: "success"` edge `S → C`: inject a synthetic `OutcomeGuard`
   node (configured `expected: :success`) wired `S → guard_S_C → C`.
2. For each `on: "failure"` edge `S → D`: inject a synthetic `OutcomeGuard`
   node (configured `expected: :failure`) wired `S → guard_S_D → D`.

Synthetic nodes are built via `build_action_node(OutcomeGuard, params, name,
index, nil)` — `nil` run_id bypasses `ActionWrapper`, so no `StepRun` row is
created for them.

**`OutcomeGuard` — new condition module
(`lib/zaq/engine/workflows/conditions/outcome_guard.ex`)**

- `:success` guard: raises `ConditionNotMet` when `params[:__outcome__] ==
  :failure`; treats absent `__outcome__` as success (pass-through). Strips
  `__outcome__` from returned fact so downstream actions see a clean map.
- `:failure` guard: raises `ConditionNotMet` when `__outcome__` is absent or
  `!= :failure`. Strips `__outcome__` from returned fact.
- FieldComparison cannot be reused — it raises on a missing key, which would
  falsely prune success branches during normal (non-failing) flow.

**`WorkflowAgent.finalize/2` — `recover` from `steps_snapshot`, no new DB field**

Post-run status rule (replaces the current "any failed row → FAILED"):

1. Collect all `"failed"` StepRun rows.
2. For each failed row, look up its outgoing `on: "failure"` edges in
   `run.steps_snapshot`.
3. A failed step is **recovered** iff: it has at least one `recover: true`
   failure edge AND every such edge's `to` target StepRun has `status:
   "completed"`.
4. Run is `"success"` iff all failed steps are recovered (and no step is stuck
   at `"running"`).
5. Mixed-recover rule: if a failed node has both `recover: true` and
   `recover: false` failure edges, the `recover: false` edge dominates — run is
   `"FAILED"`.
6. No failure edge from a failed node → `"FAILED"` (current behavior preserved).

`recover` never needs to flow into `ActionWrapper` or `StepRun` — it is read
from `steps_snapshot` at finalize time. No schema migration or new DB field.
