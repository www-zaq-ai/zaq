# Plan: Edge Condition Trace Observability

## Goal

When an `EdgeStep` evaluates a condition and it fails, the fact that the condition was evaluated, what the result was, and which downstream step was pruned must appear in the run trace. Currently this information is completely invisible.

## Current Gap (documented by tests)

`test/zaq/engine/workflows/edge_routing_test.exs` — "trace completeness" describe block confirms:

- EdgeStep guard nodes write no `Step.Run` row (they are not wrapped by `ActionWrapper`).
- Pruned downstream nodes write no `Step.Run` row (`ActionWrapper` is never called).
- `get_run_trace/1` returns only actually-executed steps; condition evaluation and branch pruning are absent.
- No condition metadata (`field`, `op`, `actual`, `expected`) appears anywhere in the trace.

## Target Behavior

After this plan, for a run where an edge condition fails:

- The EdgeStep guard for the failing edge writes a `Step.Run` row with `status: "skipped"` and `results` containing `%{field, op, actual, expected, edge_name}`.
- The pruned downstream node still writes **no** `Step.Run` row (it was never executed — that is correct).
- `get_run_trace/1` includes the EdgeStep guard row, making branch pruning and the reason for it visible.

---

## Pre-Planning Audit

| Question | Answer |
|---|---|
| Does `EdgeStep` currently receive `run_id`? | No — `DagBuilder.build_edge_step_node/3` only passes `__edge_condition__`, `__edge_mapping__`, `__edge_name__` |
| Does `ActionWrapper` wrap EdgeStep? | No — and it should stay that way (EdgeStep is infrastructure) |
| Does `Step.Run` support `"skipped"` status? | Yes — already in `@statuses` and `skip_step_run/3` exists in `Workflows` |
| Does `Workflows.create_step_run/3` need changes? | No |
| Does `get_run_trace` need changes? | No — it maps all `Step.Run` rows; EdgeStep rows will appear automatically |

---

## Steps

---

### Step 1 — Pass `run_id` to EdgeStep via DagBuilder

**Module**: `Zaq.Engine.Workflows.DagBuilder`

**Functional spec**:

In `build_edge_step_node/3`, when a `run_id` is present in opts, include it in the EdgeStep params:

```elixir
defp build_edge_step_node(condition, mapping, name, run_id) do
  params =
    %{
      __edge_condition__: condition,
      __edge_mapping__: mapping,
      __edge_name__: name
    }
    |> then(fn p -> if run_id, do: Map.put(p, :run_id, run_id), else: p end)

  ActionNode.new(EdgeStep, params, name: String.to_atom(name))
end
```

`EdgeStep.run/2` already strips unknown keys before passing the fact downstream — `run_id` must also be stripped from the fact output (add `:run_id` to `@edge_keys`).

**Tests to add before implementation** (`test/zaq/engine/workflows/dag_builder_test.exs`):
- When `run_id` is provided to `DagBuilder.build/2`, the EdgeStep node params contain `:run_id`.
- When `run_id` is absent, EdgeStep params do not contain `:run_id`.

**Branches/paths validated**: `run_id` present; `run_id` absent.

**Mocking plan**: none.

**Docs to update**: `docs/services/workflows.md` — EdgeStep note.

---

### Step 2 — EdgeStep writes a `Step.Run` row on condition failure

**Module**: `Zaq.Engine.Workflows.Steps.EdgeStep`

**Functional spec**:

In `maybe_check_condition/3`, when `run_id` is present in params and the condition fails, write a `Step.Run` row with `status: "skipped"` before raising `ConditionNotMet`:

```elixir
defp maybe_check_condition(condition, fact, edge_name, run_id) do
  ...
  unless EdgeCondition.evaluate(op, actual, expected) do
    if run_id do
      {:ok, step_run} =
        Workflows.create_step_run(%WorkflowRun{id: run_id}, %{
          step_name: edge_name,
          step_index: -1,
          status: "running"
        })

      Workflows.skip_step_run(step_run, %{
        field: field,
        op: to_string(op),
        actual: inspect(actual),
        expected: inspect(expected)
      })
    end

    raise ConditionNotMet, ...
  end
end
```

Notes:
- `step_index: -1` distinguishes EdgeStep guard rows from action rows (guards are between steps, not at a specific index). Consider adding a dedicated `step_type` field in the separate schema plan, or use `step_index: -1` as a convention documented in the `Step.Run` moduledoc.
- Write the `Step.Run` row only when the condition **fails** — a passing EdgeStep is infrastructure noise and should remain invisible.
- `run_id` is `nil` in unit-test / non-instrumented builds (no `run_id` in `DagBuilder.build/2` opts). The guard `if run_id` handles this.

**Tests to add before implementation** (`test/zaq/engine/workflows/steps/edge_step_test.exs`):
- When condition fails and `run_id` is present: a `Step.Run` row is written with `status: "skipped"` and condition metadata in `results`.
- When condition fails and `run_id` is absent: no `Step.Run` row is written; `ConditionNotMet` is still raised.
- When condition passes: no `Step.Run` row is written regardless of `run_id`.

**Branches/paths validated**: fail + run_id; fail + no run_id; pass + run_id; pass + no run_id.

**Mocking plan**: none — use real DB for rows, unit test for no-run_id case.

**Docs to update**: `docs/services/workflows.md` — execution flow, EdgeStep note.

---

### Step 3 — Update trace completeness tests to assert new behavior

**Module**: `test/zaq/engine/workflows/edge_routing_test.exs`

**Functional spec**:

Update the "trace completeness" describe block assertions to reflect the fixed behavior:

- `get_run_trace` now includes EdgeStep guard rows with `status: "skipped"`.
- Guard row `step_name` matches the pattern `"B__to__C__edge"`.
- Guard row `results` contains `field`, `op`, `actual`, `expected`.
- Pruned downstream action nodes (C, D, F) still have **no** `Step.Run` row.

The existing `refute` assertions will invert to `assert` for condition metadata visibility.

**Tests to update**:
- "get_run_trace omits pruned branches entirely — no skipped rows" → becomes "get_run_trace includes EdgeStep guard rows for failed conditions".
- "EdgeStep guard nodes leave no Step.Run row" → inverts to "EdgeStep guard nodes write a skipped Step.Run row on condition failure".
- "condition metadata is absent from the trace" → inverts to "condition metadata (field, op, actual, expected) is present in the EdgeStep guard row".

**Mocking plan**: none.

**Docs to update**: none (tests are self-documenting).

---

## Dependency Order

```
Step 1 (DagBuilder — pass run_id to EdgeStep)
  └─> Step 2 (EdgeStep — write Step.Run on condition failure; needs run_id in params)
        └─> Step 3 (update trace tests to assert new behavior)
```

---

## Coverage Policy

Every file touched must reach ≥ 95% coverage. Files in scope:
- `lib/zaq/engine/workflows/dag_builder.ex`
- `lib/zaq/engine/workflows/steps/edge_step.ex`
- `test/zaq/engine/workflows/edge_routing_test.exs` (test file — covered by definition)

---

## Definition of Done

- [ ] EdgeStep writes a `Step.Run` row with `status: "skipped"` and condition metadata when a condition fails and `run_id` is present.
- [ ] EdgeStep writes no row when condition passes.
- [ ] `get_run_trace` returns the EdgeStep guard row with field/op/actual/expected.
- [ ] Pruned downstream action nodes still have no `Step.Run` row.
- [ ] The 3 trace completeness tests in `edge_routing_test.exs` pass with inverted assertions.
- [ ] All touched files ≥ 95% coverage.
- [ ] `mix precommit` passes.
