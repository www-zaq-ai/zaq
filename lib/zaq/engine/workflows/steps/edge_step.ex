defmodule Zaq.Engine.Workflows.Steps.EdgeStep do
  @moduledoc """
  Infrastructure Jido.Action injected by `DagBuilder` on edges that carry a
  `condition` and/or a `mapping`.

  ## Contract (D-1)

  - **Input**: the upstream node's output fact (atom-keyed map), merged with the
    edge's static metadata keys (`__edge_condition__`, `__edge_mapping__`,
    `__edge_name__`) by Runic's ActionNode execution.
  - **Condition present and false**: raises `ConditionNotMet` — Runic marks this
    step `:failed` and prunes the downstream subgraph via `skip_downstream_subgraph`.
    The downstream action node's `StepRunner` never runs → no failed `StepRun`
    row → `finalize/2` sees the run as `"completed"` (or `"incomplete"` when no
    leaf is ever reached).
  - **Mapping**: source keys listed as mapping values are consumed (removed from the
    output); all other keys are passed through unchanged; target keys are added.
    A mapped value that is (or contains) a struct passes through unnormalized —
    only plain map/list values have their keys atomized.
  - **Output**: `{:ok, transformed_fact}` — the downstream node's `StepRunner`
    receives this as its input fact.

  ## Failure semantics (edge condition/mapping crash vs. condition-not-met)

  A `completed` `StepRun` row is written **only after the mapping succeeds** —
  never before. Three outcomes:

  | Outcome                          | StepRun row               | Run status effect                    |
  |-----------------------------------|----------------------------|---------------------------------------|
  | condition true (or absent) + mapping ok | `completed`         | run may finalize `completed`          |
  | condition false (`ConditionNotMet`)     | `skipped`            | downstream pruned; run may finalize `incomplete` if no leaf is reached |
  | unexpected raise (bad op, mapping crash, etc.) | `failed`      | downstream pruned; run finalizes `failed` with the edge in `failed_steps` |

  An unexpected raise (anything other than `ConditionNotMet`) is caught, an
  idempotent `failed` `StepRun` row is written (same idempotency guard as the
  `completed`/`skipped` writers — safe under Jido retry), and the exception is
  reraised unchanged. Runic still prunes the downstream subgraph either way; the
  row is what lets `finalize/2` tell an infrastructure crash apart from a
  legitimate pruned branch.

  This module is NOT wrapped by `StepRunner` (see D-3). It is infrastructure;
  it never appears in `StepRun` rows except via the `failed`/`skipped`/`completed`
  guard rows written above.
  """

  use Jido.Action, name: "zaq_edge_step", schema: []

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.EdgeCondition
  alias Zaq.Engine.Workflows.FactLookup
  alias Zaq.Engine.Workflows.WorkflowRun

  @edge_keys [
    :__edge_condition__,
    :__edge_mapping__,
    :__edge_name__,
    :__edge_source_index__,
    :run_id
  ]

  @impl true
  def run(params, _context) do
    condition = Map.get(params, :__edge_condition__)
    mapping = Map.get(params, :__edge_mapping__) || %{}
    edge_name = Map.get(params, :__edge_name__, "edge")
    run_id = Map.get(params, :run_id)
    source_index = Map.get(params, :__edge_source_index__, 0)

    fact = Map.drop(params, @edge_keys)

    try do
      maybe_check_condition(condition, fact, edge_name, run_id, source_index)
      # Compute the mapped output BEFORE writing the "completed" row — a crash
      # here must never leave a `completed` StepRun row for an edge that
      # produced no fact (see the `rescue` clause below).
      output = apply_mapping(fact, mapping)
      write_pass_trace(run_id, edge_name, source_index)

      {:ok, output}
    rescue
      e in ConditionNotMet ->
        # Existing skip semantics: write_skip_trace/5 already ran inside
        # maybe_check_condition/5 — reraise unchanged.
        reraise e, __STACKTRACE__

      e ->
        # Any other raise is infrastructure-level and otherwise invisible: Runic
        # prunes the downstream subgraph silently (same as ConditionNotMet) with
        # no failed row and no log. Write a failed StepRun row so `finalize/2`
        # marks the run `"failed"` (with this edge in `failed_steps`) instead of
        # a silent `"incomplete"`, then reraise — Runic still prunes downstream.
        write_fail_trace(run_id, edge_name, source_index, e)

        reraise e, __STACKTRACE__
    end
  end

  defp maybe_check_condition(nil, _fact, _name, _run_id, _source_index), do: :ok

  defp maybe_check_condition(condition, fact, edge_name, run_id, source_index) do
    field = condition["field"] || condition[:field]
    op = to_op(condition["op"] || condition[:op])
    expected = Map.get(condition, "value", Map.get(condition, :value))
    type = condition["type"] || condition[:type]
    actual = lookup(fact, field)

    unless EdgeCondition.evaluate(op, actual, expected, type: type) do
      write_skip_trace(run_id, edge_name, source_index, field, op, actual, expected)

      raise ConditionNotMet,
        condition_name: edge_name,
        field: field,
        op: op,
        actual: actual,
        expected: expected
    end
  end

  # Writes a Step.Run row with status "completed" when a condition passes (or no
  # condition). Idempotent — Jido may retry, so we skip if a row already exists.
  defp write_pass_trace(nil, _edge_name, _source_index), do: :ok

  defp write_pass_trace(run_id, edge_name, source_index) do
    unless Workflows.get_step_run_by_name(run_id, edge_name) do
      {:ok, step_run} =
        Workflows.create_step_run(%WorkflowRun{id: run_id}, %{
          step_name: edge_name,
          step_index: source_index,
          status: "running"
        })

      Workflows.complete_step_run(step_run, %{})
    end
  end

  # Writes a Step.Run row with status "skipped" when a condition fails and the
  # run is instrumented (run_id present). Idempotent — Jido may retry on failure,
  # so we only write if no row already exists for this edge name.
  defp write_skip_trace(nil, _edge_name, _source_index, _field, _op, _actual, _expected), do: :ok

  defp write_skip_trace(run_id, edge_name, source_index, field, op, actual, expected) do
    unless Workflows.get_step_run_by_name(run_id, edge_name) do
      {:ok, step_run} =
        Workflows.create_step_run(%WorkflowRun{id: run_id}, %{
          step_name: edge_name,
          step_index: source_index,
          status: "running"
        })

      Workflows.skip_step_run(step_run, %{
        field: field,
        op: to_string(op),
        actual: inspect(actual),
        expected: inspect(expected)
      })
    end
  end

  # Writes a Step.Run row with status "failed" when the condition check or
  # mapping raises unexpectedly. Idempotent — Jido may retry, so we skip if a
  # row already exists for this edge name (same guard as write_pass_trace /
  # write_skip_trace). No-op without a run_id (uninstrumented run).
  defp write_fail_trace(nil, _edge_name, _source_index, _exception), do: :ok

  defp write_fail_trace(run_id, edge_name, source_index, exception) do
    unless Workflows.get_step_run_by_name(run_id, edge_name) do
      {:ok, step_run} =
        Workflows.create_step_run(%WorkflowRun{id: run_id}, %{
          step_name: edge_name,
          step_index: source_index,
          status: "running"
        })

      Workflows.fail_step_run(step_run, %{reason: Exception.message(exception)})
    end
  end

  defp apply_mapping(fact, mapping) when map_size(mapping) == 0, do: fact

  defp apply_mapping(fact, mapping) do
    source_atom_keys = MapSet.new(mapping, fn {_t, s} -> to_key(s) end)

    base = Map.drop(fact, MapSet.to_list(source_atom_keys))

    remapped =
      Map.new(mapping, fn {target, source} ->
        {to_key(target), lookup(fact, source) |> normalize_value()}
      end)

    Map.merge(base, remapped)
  end

  # Normalize keys of values extracted from the JSONB cascade so downstream
  # actions can use atom-key access regardless of whether the run resumed from DB.
  # Only data that flows through an edge mapping is normalized — unmodified cascade
  # facts (e.g. raw email maps) are left untouched.
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)

  # A struct's keys are already atoms — there is nothing to normalize, and
  # `Map.new/2` (the map clause below) crashes on structs with
  # `Protocol.UndefinedError` because they are not `Enumerable`. Structs pass
  # through untouched; JSONB persistence still flattens them on the way out
  # via `StepRunner.json_safe/1`, unchanged.
  defp normalize_value(%_{} = struct), do: struct

  defp normalize_value(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {try_to_atom(k), normalize_value(v)}
      {k, v} -> {k, normalize_value(v)}
    end)
  end

  defp normalize_value(other), do: other

  defp try_to_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  # Resolve a field/source reference against the fact via the shared cascade-aware
  # resolver. Edge routing treats an absent reference as `nil` (a false condition,
  # or a nil-mapped value), so the `{:ok, _} | :error` contract is collapsed here.
  # See `FactLookup` for the supported `"field"` / `"step.field"` / `"step.map.field"`
  # forms.
  defp lookup(fact, key) do
    case FactLookup.fetch(fact, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  # Convert a string key to an existing atom, falling back to the original
  # string if the atom has never been interned (avoids atom exhaustion).
  defp to_key(s) when is_binary(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> s
  end

  defp to_key(k), do: k

  # Convert a string or atom op to an atom understood by EdgeCondition.
  defp to_op(op) when is_atom(op), do: op

  defp to_op(op) when is_binary(op) do
    String.to_existing_atom(op)
  rescue
    ArgumentError -> op
  end
end
