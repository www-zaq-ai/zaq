# Execution Plan — Conditional & Data-Connector Edges

> Tracked as a plan file by explicit user instruction (not Beadwork).
> Conforms to `docs/exec-plans/PLAN_STRATEGY.md`.

---

## Original Requirement (verbatim, from the user)

> In the workflow we have nodes and edges.
>
> We want the edges to hold the conditional operation so it will decide the route of the
> next action. Say we have a workflow made of
>
> ```
> A -> B -> C -> D
>      B -> F
> ```
>
> So the edge handling the connection between `B`→`C` and `B`→`F` should decide the route.
>
> Also the edge is a **data connector**.
>
> ```elixir
> %OutputB{name: "", age: "", gender: ""}
> ```
>
> edge: if gender is male go to `C`, if female go to `F`
>
> edge also knows how to connect the output of `B` to the `C` and `F` node — maybe `name`
> in `B` is `person_name` in `C` and in `F` it's `first_name`.
>
> So currently we have the **conditional node which should be removed** and this logic
> should go to the edge.
>
> In the plan I want to see the test I explained written; the implementation must make
> that scenario pass.

---

## Goal

1. **Edges decide routing.** An edge may carry a *condition* evaluated against the
   upstream node's output. If false, the downstream branch is pruned; if true (or no
   condition), the branch is taken.
2. **Edges are data connectors.** An edge may carry a *mapping* that renames the
   upstream node's output keys into the input keys the downstream node expects
   (`name` → `person_name` for `B`→`C`; `name` → `first_name` for `B`→`F`).
3. **Remove the `condition` node type.** Routing logic moves out of
   `"type": "condition"` nodes (`Conditions.FieldComparison` + module-backed
   conditions) and onto edges. The node type is deleted, not deprecated.
4. **The user's exact scenario is a committed integration test** that drives the real
   `WorkflowAgent`/`DagBuilder`/Runic boundary and must pass at Definition of Done.

Out of scope (tracked elsewhere): the adjacent
`docs/exec-plans/active/2026-05-19-failure-routing-edges.md` adds `on: success|failure`
+ `recover` to edges (route on *outcome*). This plan routes on *output data values* and
owns the `condition`/`mapping` edge attributes. The two are orthogonal edge attributes;
see **Decisions Log → D-2** for the reconciliation contract.

---

## Pre-Planning Infrastructure Audit (Mandatory)

Domain: `lib/zaq/engine/workflows/`. Findings from reading each module's `@moduledoc`
and source:

| Concern | Existing home | Reuse decision |
|---|---|---|
| Edge data model | `Zaq.Engine.Workflows.Step.Edge` (`step/edge.ex`) — `from`/`to` only; in-code comment already states *"This file will change it should contain the mapping between previous node outputs and the next node inputs"* | **Extend** the existing embedded schema. Add `condition` (embedded) + `mapping` (map). `@moduledoc` amended. No new schema module. |
| Comparison op vocabulary | `Zaq.Engine.Workflows.Conditions.FieldComparison` — `Ecto.Enum` ops `eq,neq,gt,lt,gte,lte,not_empty,empty,in` + `compare/3` + `cast_op/1` | **Relocate** the pure comparator to one home (`Zaq.Engine.Workflows.Predicate`). The op vocabulary must have a single home once `FieldComparison` is deleted (AGENTS.md "one home" rule). |
| DAG assembly | `Zaq.Engine.Workflows.DagBuilder` — `build/2`; `build_node("condition", …)`; `assemble/2` wires nodes with unconditional `Runic.Workflow.add(wf, node, to:, validate: :off)` | **Extend** assembly: delete `condition` node branches; inject a per-edge guard/transform step when an edge has `condition` and/or `mapping`. No parallel builder. `@moduledoc` example + Node-types text rewritten. |
| Branch pruning idiom | Condition nodes raise `ConditionNotMet`; Runic's `skip_downstream_subgraph/2` relabels descendants' pending edges `:upstream_failed` and the drive loop terminates that branch (`JIDO_RUNIC_EVENT_FLOW.md` §5) | **Mirror** this proven idiom for edge conditions — raise to prune. Do **not** invent a new pruning mechanism. |
| Per-step input | Runic does **NOT** accumulate facts: step N+1 sees only step N's output map overlaid on its own static `params` (`JIDO_RUNIC_EVENT_FLOW.md` §6) | This is *why* the mapping must live on the edge — there is no accumulated context to remap from later. The injected edge step transforms `from`'s output into `to`'s input. |
| Fan-out / fan-in | Multiple incoming edges → `Runic.Workflow.Join` (Coordinator) withholds until all parents arrive (`JIDO_RUNIC_EVENT_FLOW.md` §4). A node with multiple *outgoing* edges feeds its output fact to every structurally-connected successor unless that branch is pruned. | Conditional routing = prune all-but-the-matching outgoing branch via the raise idiom. Fan-in interaction with injected guard steps **must be verified in the Step 1 spike**. |
| Step execution + StepRun cursor | `Zaq.Engine.Workflows.ActionWrapper` — `create_step_run` (running) → `complete_step_run`/`fail_step_run`; `ConditionNotMet` → recorded `"skipped"` (not `"failed"`) | **Reuse**. The injected edge step's prune raise must be the same exception family so a pruned branch is `"skipped"`, not `"failed"`. `ConditionNotMet` rescue branch unchanged in shape. |
| Run-final status | `Zaq.Engine.Workflows.WorkflowAgent.finalize/2` — any `"failed"`/`"running"` StepRun → run `"failed"`; otherwise `"completed"` | **Reuse, verify**: a pruned (not-taken) branch must leave the run `"completed"`, never `"failed"`. Regression-test this. |

**Key risk identified by the audit:** the exact Runic mechanics of a *step injected on
an edge* (vs. today's condition that is a first-class node) under fan-out and fan-in are
unproven — specifically (a) whether a guard step between `B` and `C` correctly prunes
*only* the `C` subgraph while `B`→`F` still runs, and (b) how the injected step interacts
with a downstream `Join` if `C` later fans in. **This must be resolved in Step 1 before
dependent steps are designed in detail.**

---

## Module Responsibility Confirmation

1. `Zaq.Engine.Workflows.Step.Edge` — owns edge shape/validation. `condition` + `mapping`
   are edge attributes → fits its `@moduledoc` ("directed edge between two nodes";
   in-code comment already anticipates the mapping). `@moduledoc` will be amended.
2. `Zaq.Engine.Workflows.Predicate` (**new**) — single home for the comparison-op
   vocabulary + pure `evaluate/3`. Justified: once `FieldComparison` is deleted the op
   vocabulary would otherwise have no home; cross-cutting predicate logic gets one home
   (AGENTS.md rule).
3. `Zaq.Engine.Workflows.Step.EdgeStep` (**new**) — the Runic step DagBuilder injects per
   conditional/mapping edge: evaluate condition (raise to prune on false), then apply
   mapping to produce the downstream input fact. Owns *runtime* edge behavior; `Step.Edge`
   owns the *data model*. Clean split, no overlap.
4. `Zaq.Engine.Workflows.DagBuilder` — owns `steps`→`Runic.Workflow` assembly. Deleting
   `condition` node handling and injecting `EdgeStep` is assembly → fits. No parallel
   builder.
5. `Zaq.Engine.Workflows.ActionWrapper` / `WorkflowAgent` — unchanged responsibilities;
   reused as-is. Verified, not modified (unless Step 1 proves a minimal change is
   unavoidable — that would be a recorded decision).

No cross-cutting concern (credentials / URL formatting / permission checks) is pulled
into any of these modules.

New public function signatures use a trailing `opts \\ []` for future-proofing.

---

## Security Checklist

This path touches **no** permission filtering, `person_id`, `skip_permissions`, or data
access scope. `Zaq.Engine.Workflows` explicitly delegates permission checks to callers
(per its `@moduledoc`). Edge `condition`/`mapping` operate solely on in-run fact data
already inside an authorized run.

- Can `person_id: nil` reach this path? **N/A** — no `person_id` parameter exists on any
  function added/modified here. The injected edge step receives only the upstream fact
  map. No negative test required because there is no permission branch to bypass; this is
  asserted by the absence of any `person_id`/`skip_permissions` reference in the touched
  modules (grep gate in Step 7).

---

## Test Strategy (Mandatory)

- **Integration-first.** The user scenario (Step 6) drives real
  `WorkflowAgent.execute/2` → `DagBuilder` → Runic → `ActionWrapper` → `StepRun` rows.
  No seams stubbed.
- Unit tests only where a pure boundary exists (`Predicate.evaluate/3`, `Step.Edge`
  changeset, `EdgeStep` transform).
- **No mocks.** Every dependency in this feature is a ZAQ primitive (Runic is a vendored
  dep exercised through its real API, never mocked). **Mocking plan for all steps: N/A.**
- Test helper actions for Step 6 live in `test/support` alongside the existing
  `Zaq.Engine.Workflows.Test.OkAction` family (do not add throwaway modules to `lib/`).
- Property test: `Predicate.evaluate/3` over generated `{op, actual, expected}` triples
  (total function, never raises for valid ops; raises `ArgumentError` only for unknown
  op) — invariant surface is broad → property test required per `docs/testing-approach.md`.

---

## Coverage Policy

Every file added or modified must reach **≥ 95%** line coverage (project floor is 90%;
PLAN_STRATEGY mandates 95% for plan closure). Verified in Step 7 via
`mix test --cover` scoped to the touched files. Any shortfall is documented in the
Decisions Log **and** the PR description with a follow-up.

---

## Dependency Graph (DAG — no Beadwork, encoded here)

```
Step 1 (spike + decision record)
   ├─> Step 2 (Step.Edge schema: condition + mapping)
   └─> Step 3 (Predicate + EdgeStep runtime)
Step 2, Step 3 ──> Step 4 (DagBuilder: inject EdgeStep, drop condition node)
Step 4 ──> Step 5 (delete FieldComparison + condition node type, relocate exception)
Step 4, Step 5 ──> Step 6 (end-to-end user scenario integration test)
Step 6 ──> Step 7 (docs, coverage ≥95%, mix precommit, DoD)
```

- Acyclic. The only join (`2 ∧ 3 → 4`) is required and justified: wiring needs both the
  validated data model and the runtime step. No unjustified diamonds.
- Step order respects dependencies: primitives (schema, predicate, runtime step) before
  the assembler that consumes them; deletion (Step 5) after the new path exists (Step 4)
  so the build is never red between merges.

---

## Step 1 — Runic edge-injection spike + decision record

**1. Functional specifications + files**
Prove (or disprove) that a step injected by `DagBuilder` *on an edge* between `from` and
`to` can:
- (a) raise to prune **only** `to`'s subgraph while a sibling edge `from`→`other` still
  runs (conditional fan-out routing), and
- (b) pass a transformed fact through to `to` on success, and
- (c) behave correctly when `to` later fans in to a `Join`, and
- (d) produce the **same** StepRun outcome as today's condition node for a pruned branch
  (`"skipped"`, run stays `"completed"`).
Candidate mechanisms:
- **(A)** Inject a `Runic.Workflow.Step` (or `Jido.Runic.ActionNode` wrapping a tiny
  module) between `from` and `to`; condition-false → raise (reusing the
  `skip_downstream_subgraph` idiom from `JIDO_RUNIC_EVENT_FLOW.md` §5).
- **(B)** If (A) cannot prune a single sibling branch cleanly, fall back to a
  guard that emits a sentinel the downstream consumes — recorded only if (A) fails.
Files: **spike characterization test only**, no production code. **Decision recorded in
this file's Decisions Log (D-1).**

**2. Tests to add before implementation**
`test/zaq/engine/workflows/dag_builder_test.exs` — characterization test built by hand
(hand-assembled Runic graph mirroring the intended injection): `A→B`, `B→C` (guard:
false), `B→F` (guard: true) ⇒ `F` runs, `C` pruned, `A`/`B`/`F` complete. Written before
the mechanism is committed.

**3. Branches/paths validated** — guard true → pass-through; guard false → prune that
branch only; sibling branch unaffected; downstream `Join` after a guarded edge; pruned
branch StepRun = skipped, run = completed.

**4. Mocking plan** — N/A (real Runic).

**5. Docs to update** — Decisions Log entry **D-1** recording the chosen mechanism and
the exact "edge step" contract (input = `from` output fact; output = mapped fact;
prune-raise exception type) consumed by Steps 3 & 4.

---

## Step 2 — `Step.Edge` schema: `condition` + `mapping`

**1. Functional specifications + files** (depends_on: Step 1)
- `lib/zaq/engine/workflows/step/edge.ex`:
  - Add `embeds_one :condition, Zaq.Engine.Workflows.Step.Edge.Condition` (new embedded
    schema: `field :string`, `op` `Ecto.Enum` reusing the Step-3 `Predicate` op set,
    `value :any`). Absent → unconditional edge.
  - Add `field :mapping, :map, default: %{}` — JSON object of
    `target_input_key => source_output_key`. Empty → identity pass-through.
  - `changeset/2`: `cast` + `cast_embed(:condition)`; keep `from`/`to` required;
    `mapping` keys/values validated as non-empty strings; reject a `condition` with an
    op outside the `Predicate` vocabulary (delegated to the embedded changeset).
  - Replace the in-code "This file will change…" comment; amend `@moduledoc` to document
    `condition`/`mapping` and the no-SQL-migration note (`embeds_many` JSONB).
- `lib/zaq/engine/workflows/workflow.ex` — already `cast_embed(:edges)`; verify defaults
  round-trip through the JSONB embed (no migration needed).

**2. Tests to add before implementation**
- `test/zaq/engine/workflows/steps/edge_test.exs` (create): defaults
  (`condition=nil`, `mapping=%{}`); valid condition; invalid op rejected; non-string
  mapping rejected; `from`/`to` still required; back-compat — `%{from,to}`-only edge
  still valid.
- `test/zaq/engine/workflows/steps/workflow_steps_test.exs` — `Workflow.changeset`
  round-trips an edge with `condition`+`mapping` through the embed (active status).

**3. Branches/paths validated** — bare edge (back-compat); condition-only; mapping-only;
both; invalid op; invalid mapping; missing `from`/`to`.

**4. Mocking plan** — N/A.

**5. Docs to update** — `Step.Edge`/`Step.Edge.Condition` `@moduledoc`;
`docs/services/workflows.md` "Steps JSONB Format" → Edge fields.

---

## Step 3 — `Predicate` + `EdgeStep` runtime primitives

**1. Functional specifications + files** (depends_on: Step 1)
- `lib/zaq/engine/workflows/predicate.ex` (**new**): single home for the op vocabulary.
  `@ops` enum (`eq,neq,gt,lt,gte,lte,not_empty,empty,in`), `evaluate(op, actual,
  expected) :: boolean`, `cast_op/1`. Pure; lifted verbatim from `FieldComparison`'s
  `compare/3`+`cast_op/1` (behavior-preserving move). Trailing `opts \\ []` reserved.
- `lib/zaq/engine/workflows/step/edge_step.ex` (**new**): the unit DagBuilder injects.
  Given `condition`, `mapping`, and the upstream output fact:
  - condition present and `Predicate.evaluate/3` false → raise the prune exception
    chosen in D-1 (same family as `ConditionNotMet` so `ActionWrapper` records
    `"skipped"`);
  - else apply `mapping`: produce `%{target_key => Map.get(fact, source_key)}` for each
    mapping pair, pass through unmapped keys per the D-1 contract, return the transformed
    map as the downstream input fact.
  - Pure transform fn + a thin builder returning the Runic node, so DagBuilder stays an
    assembler.

**2. Tests to add before implementation**
- `test/zaq/engine/workflows/predicate_test.exs`: each op true/false; `in` requires list;
  unknown op → `ArgumentError`; **property**: total over generated triples.
- `test/zaq/engine/workflows/step/edge_step_test.exs`: no condition → identity/mapping
  only; condition true → mapped output; condition false → raises prune exception;
  mapping renames keys (`name`→`person_name`); unmapped-key behavior matches D-1;
  missing source key → mapped value `nil` (documented).

**3. Branches/paths validated** — all ops; condition true/false/absent; mapping
empty/partial/full; missing source key; unknown op.

**4. Mocking plan** — N/A.

**5. Docs to update** — `Predicate`/`EdgeStep` `@moduledoc`; cross-link from
`docs/services/workflows.md`.

---

## Step 4 — `DagBuilder`: inject `EdgeStep`, route on edges

**1. Functional specifications + files** (depends_on: Step 2, Step 3)
- `lib/zaq/engine/workflows/dag_builder.ex`:
  - In `assemble/2`/`add_node/4`: for each edge with a `condition` and/or non-empty
    `mapping`, insert an `EdgeStep` (Step 3) between `from` and `to` using the D-1
    mechanism; plain `%{from,to}` edges keep today's unconditional
    `Runic.Workflow.add(to:, validate: :off)` wiring **unchanged** (regression).
  - When `run_id` present: decide per D-1 whether the injected `EdgeStep` is itself
    wrapped by `ActionWrapper` (preferred: **not** wrapped — it is infrastructure; the
    pruned downstream action's StepRun is what records `"skipped"`, preserving current
    observability). Decision recorded as **D-3**.
  - `validate_edges/2`: a conditional edge's `to` validated like any edge; an edge whose
    `condition.op` is unknown → `{:error, {:invalid_edge_condition, …}}` (build refuses,
    mirroring the existing `contract_violation` style).
  - Rewrite `@moduledoc` "Expected input format" + Node-types text: drop `condition`
    node type, show an edge with `condition`+`mapping`.

**2. Tests to add before implementation**
`test/zaq/engine/workflows/dag_builder_test.exs`:
- Regression: linear `%{from,to}`-only DAG assembles byte-for-byte unchanged.
- `A→B`, `B→C` (cond gender=male), `B→F` (cond gender=female): builds; both branches
  present pre-execution.
- Mapping-only edge (no condition) builds and renames.
- Conditional edge with unknown op → `{:error, {:invalid_edge_condition, _}}`.
- Conditional edge `to` unknown node → `{:error, {:unknown_node, _}}`.
- `run_id` present → injected `EdgeStep` instrumented per D-3.

**3. Branches/paths validated** — bare edge regression; condition fan-out; mapping-only;
invalid op; unknown target; instrumented vs. non-instrumented build.

**4. Mocking plan** — N/A.

**5. Docs to update** — `DagBuilder` `@moduledoc`; `docs/services/workflows.md`
DAG-engine + "Steps JSONB Format" + Fact-Flow sections.

---

## Step 5 — Delete the `condition` node type

**1. Functional specifications + files** (depends_on: Step 4)
- Delete `lib/zaq/engine/workflows/conditions/field_comparison.ex`.
- Remove `build_node("condition", …)` clauses + the `FieldComparison` alias/usage from
  `lib/zaq/engine/workflows/dag_builder.ex`; an incoming `"type": "condition"` node now
  returns `{:error, {:unknown_node_type, "condition"}}` (existing catch-all).
- Relocate the prune exception: keep `Zaq.Engine.Workflows.Conditions.ConditionNotMet`
  **or** rename to `Zaq.Engine.Workflows.Step.EdgeConditionNotMet` per D-1; update
  `ActionWrapper`'s rescue/`"skipped"` branch to reference the chosen module (shape of
  the branch unchanged — only the alias).
- Remove now-dead `condition`-node tests from `dag_builder_test.exs`
  (`Always/NeverCondition`, inline-cond, op-matrix) — those paths are re-covered by
  `predicate_test.exs` + `edge_step_test.exs`.
- Clean any seed/example/fixture workflow JSON and `test/support` helpers that use
  `"type": "condition"`.

**2. Tests to add before implementation**
- `dag_builder_test.exs`: `"type": "condition"` node → `{:error,
  {:unknown_node_type, "condition"}}` (explicit removal assertion).
- Grep gate test/CI check: no `"type": "condition"` and no `Conditions.FieldComparison`
  reference remains in `lib/`, `test/support`, fixtures, or `docs/`.

**3. Branches/paths validated** — condition node now rejected; `ConditionNotMet`/renamed
exception still flows to `ActionWrapper` `"skipped"`; no orphan references.

**4. Mocking plan** — N/A.

**5. Docs to update** — `docs/services/workflows.md`: delete "Adding a New Condition
Type", "Node types: condition", invariant #1 wording about `Runic.condition/2`; update
"What NOT to Do". Note the breaking JSONB-contract change (see **D-4**: pre-production,
clean removal accepted).

---

## Step 6 — End-to-end user scenario (the mandated test)

**1. Functional specifications + files** (depends_on: Step 4, Step 5)
Implement the user's exact scenario as a committed integration test through real
boundaries (`WorkflowAgent.execute/2` → DagBuilder → Runic → ActionWrapper → StepRun).
- Test helper actions in `test/support` (NOT `lib/`), each satisfying the
  `Zaq.Engine.Workflows.Action` contract (`on_success/2`, `on_failure/2`, non-empty
  `schema/0`+`output_schema/0`):
  - `EmitPerson` (node `B`): `run/2 → {:ok, %{name: "Sam", age: 30, gender: <param>}}`.
  - `RequirePersonName` (node `C`): asserts it received `person_name` (and **not**
    `name`), returns `{:ok, %{c_ran: true, person_name: …}}`.
  - `RequireFirstName` (node `F`): asserts it received `first_name`, returns
    `{:ok, %{f_ran: true, first_name: …}}`.
  - `Noop` (nodes `A`, `D`): pass-through.
- Workflow JSON:
  ```
  nodes: A, B, C, D, F  (all "action")
  edges:
    A → B
    B → C  condition {field: "gender", op: "eq", value: "male"}    mapping {"person_name" => "name"}
    C → D
    B → F  condition {field: "gender", op: "eq", value: "female"}  mapping {"first_name" => "name"}
  ```

**2. Tests to add before implementation**
`test/zaq/engine/workflows/edge_routing_test.exs` (create):
- **gender = "male"**: run completes; StepRuns show `A,B,C,D` `completed`, `F`
  `skipped`/absent; `C` observed `person_name == "Sam"`; `C` did **not** see `name`;
  `D` ran after `C`.
- **gender = "female"**: run completes; `A,B,F` `completed`, `C` (and `D`)
  `skipped`/absent; `F` observed `first_name == "Sam"`.
- **gender = "other"**: neither `C` nor `F` taken; run still `"completed"` (no failed
  StepRow); `A,B` `completed`.
- Mapping isolation: `C` never receives the raw `name` key (asserts the data-connector
  rename, not a passthrough merge) — consistent with Runic non-accumulation.
- Run-status regression: a pruned branch never marks the run `"failed"`.

**3. Branches/paths validated** — male route; female route; no-match route; mapping
rename correctness; non-accumulation isolation; run-status under prune.

**4. Mocking plan** — N/A (real WorkflowAgent + Runic + Repo via `Zaq.DataCase`).

**5. Docs to update** — add a worked "Conditional & data-connector edges" example to
`docs/services/workflows.md` mirroring this scenario.

---

## Step 7 — Docs, coverage, precommit (Definition of Done)

**1. Functional specifications + files** (depends_on: Step 6)
- Finalize `docs/services/workflows.md` (DAG engine, Steps JSONB, Fact Flow, edge format,
  worked example) and all touched `@moduledoc`s.
- `mix test --cover` scoped to touched files; record each file's % here and in the PR.
- `mix precommit` green.
- Move this file to `docs/exec-plans/completed/` with the Decisions Log finalized.

**2. Tests to add before implementation** — none new; this is the validation gate.

**3. Branches/paths validated** — full suite green; coverage ≥95% per touched file.

**4. Mocking plan** — N/A.

**5. Docs to update** — `docs/services/workflows.md` final pass; this plan's Decisions
Log; PR description (coverage table, breaking-change note D-4).

---

## Definition of Done

- [ ] Step-level functional specs + test definitions written **before** each step's code.
- [ ] All listed tests implemented and passing, including the **Step 6 user scenario**.
- [ ] `condition` node type fully removed; no `Conditions.FieldComparison` or
      `"type":"condition"` reference anywhere in `lib/`, `test/support`, fixtures, docs.
- [ ] Coverage ≥ 95% for every added/modified file (table in PR).
- [ ] `mix precommit` passes.
- [ ] `docs/services/workflows.md` reflects edge-based routing/mapping; no condition-node
      references remain.
- [ ] Decisions Log complete; plan moved to `docs/exec-plans/completed/`.

---

## Decisions Log

- **D-1 — Edge-injection mechanism**: Mechanism A chosen. `DagBuilder` calls
  `ActionNode.new(EdgeStep, params)` to create a guard node, wires `from → guard_node`
  and `guard_node → to` using `Runic.Workflow.add(..., validate: :off)`. Contract:
  - **Input**: upstream node's output fact map, received as `params.input`.
  - **Output**: transformed fact — for each `{target_key, source_key}` pair in `mapping`,
    `target_key` is added with the source key's value; source keys listed in `mapping` are
    excluded from output; all other keys pass through unchanged. Empty mapping = identity.
  - **Prune-exception**: `Zaq.Engine.Workflows.Conditions.ConditionNotMet` (kept; not
    renamed). `ActionWrapper` already rescues it and records `"skipped"` on the downstream
    action's `ActionResult`, so a pruned branch never marks the run `"failed"`.
  - **Fan-in**: not encountered in the Step 1 spike. The guard node participates as a
    normal Runic step so Runic `Join` behavior is unaffected.
- **D-2 — Reconciliation with failure-routing-edges plan**: `condition`/`mapping` (this
  plan) and `on`/`recover` (`2026-05-19-failure-routing-edges.md`) are independent edge
  attributes on the same `Step.Edge` schema. They compose: an edge may carry both a
  data `condition` (this plan) and an `on:"failure"` outcome route (other plan). Neither
  plan removes the other's fields. If the other plan lands first, Step 2 *adds* fields
  rather than replacing the schema; if this plan lands first, that plan does the same.
  No shared field; no merge conflict by construction.
- **D-3 — `EdgeStep` instrumentation**: EdgeStep is **not wrapped** by `ActionWrapper`,
  even when `run_id` is present. It is infrastructure — no `ActionResult` row is written
  for it. The pruned downstream action's `ActionResult` is what records `"skipped"`,
  which is sufficient for observability and consistent with how the old condition node
  behaved. No change to `ActionWrapper` was required.
- **D-4 — Breaking JSONB contract change**: removing the `condition` node type breaks any
  stored workflow / in-flight run snapshot using `"type":"condition"`. Accepted as a
  clean removal: the workflow engine is pre-production (its sample actions are marked
  *"FOR TESTING PURPOSES, WILL GET REMOVED"*); no production data migration is owed.
  Documented in the PR as a breaking change with the new edge format as the replacement.
