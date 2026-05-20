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
    The downstream action node's `ActionWrapper` never runs → no failed `StepRun`
    row → `finalize/2` sees the run as `"completed"`.
  - **Mapping**: source keys listed as mapping values are consumed (removed from the
    output); all other keys are passed through unchanged; target keys are added.
  - **Output**: `{:ok, transformed_fact}` — the downstream node's `ActionWrapper`
    receives this as its input fact.

  This module is NOT wrapped by `ActionWrapper` (see D-3). It is infrastructure;
  it never appears in `StepRun` rows.
  """

  use Jido.Action, name: "zaq_edge_step", schema: []

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet
  alias Zaq.Engine.Workflows.EdgeCondition
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

    maybe_check_condition(condition, fact, edge_name, run_id, source_index)
    write_pass_trace(run_id, edge_name, source_index)
    {:ok, apply_mapping(fact, mapping)}
  end

  defp maybe_check_condition(nil, _fact, _name, _run_id, _source_index), do: :ok

  defp maybe_check_condition(condition, fact, edge_name, run_id, source_index) do
    field = condition["field"] || condition[:field]
    op = to_op(condition["op"] || condition[:op])
    expected = Map.get(condition, "value", Map.get(condition, :value))
    actual = lookup(fact, field)

    unless EdgeCondition.evaluate(op, actual, expected) do
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

  defp apply_mapping(fact, mapping) when map_size(mapping) == 0, do: fact

  defp apply_mapping(fact, mapping) do
    source_atom_keys = MapSet.new(mapping, fn {_t, s} -> to_key(s) end)

    base = Map.drop(fact, MapSet.to_list(source_atom_keys))

    remapped =
      Map.new(mapping, fn {target, source} ->
        {to_key(target), lookup(fact, source)}
      end)

    Map.merge(base, remapped)
  end

  # Look up a key in the fact. Supports dotted cascade paths ("A.gender")
  # which navigate into the __cascade__ accumulator built by ActionWrapper.
  # Depth > 2 (e.g., "A.b.c") is not supported and returns nil with a warning.
  defp lookup(fact, key) when is_binary(key) do
    case String.split(key, ".", parts: 2) do
      [step_name, nested_key] -> lookup_cascade(fact, step_name, nested_key)
      [simple_key] -> Map.get(fact, to_key(simple_key), Map.get(fact, simple_key))
    end
  end

  defp lookup(fact, key), do: Map.get(fact, key)

  defp lookup_cascade(fact, step_name, nested_key) do
    if String.contains?(nested_key, ".") do
      require Logger

      Logger.warning(
        "[workflow] edge condition: cascade path depth > 2 is not supported, " <>
          "field=#{step_name}.#{nested_key}"
      )

      nil
    else
      cascade = Map.get(fact, :__cascade__, Map.get(fact, "__cascade__", %{}))

      case Map.get(cascade, step_name) do
        nil ->
          nil

        step_result when is_map(step_result) ->
          Map.get(step_result, to_key(nested_key), Map.get(step_result, nested_key))

        _ ->
          nil
      end
    end
  end

  # Convert a string to an atom. Uses String.to_atom/1 since field names come
  # from workflow definitions (bounded set). Safe for pre-production use.
  defp to_key(s) when is_binary(s), do: String.to_atom(s)
  defp to_key(k), do: k

  # Convert a string or atom op to an atom understood by EdgeCondition.
  defp to_op(op) when is_atom(op), do: op
  defp to_op(op) when is_binary(op), do: String.to_atom(op)
end
