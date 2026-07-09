defmodule Zaq.Agent.Tools.Workflow.Condition do
  @moduledoc """
  Checks that all specified key/value conditions hold on an input map.

  The behaviour on success and failure depends on `on_fail`:

  - `:halt` (default) — the **linear-guard** mode. All conditions pass →
    `{:ok, %{passed: true, input: input}}` (the input is passed through so the next
    step in the chain can read it). One or more fail → `{:error, reason}` where
    `reason` is a human-readable sentence naming each failed field, its expected
    value, and the actual value — e.g.
    `Condition not met: position must equal "CFO" but was "CTO"` — which stops the
    workflow step and is shown verbatim in the run view.
  - `:continue` — the **routing** mode (if/else branching). Returns
    `{:ok, %{passed: true}}` or `{:ok, %{passed: false, failed_conditions: [...]}}` so
    downstream **edges** route on the `passed` flag (node evaluates, edge routes).
    `input` is deliberately **omitted** here: passing a generic `input` through would
    clobber a downstream node's own `input` param (the fact wins on a key collision —
    e.g. `RunAgent`'s prompt template). The evaluated data is still reachable via
    cascade (`<node>.input.*`) and the persistent `start.*` namespace.

  `on_fail` may be given as an atom (`:halt` / `:continue`) or, when authored in a
  persisted workflow, as the equivalent string (`"halt"` / `"continue"`).

  ## Condition format

  Each condition is a map with a `"key"` and `"value"` entry:

      %{"key" => "active", "value" => true}
      %{"key" => "flagged", "value" => false}

  Keys are resolved through `Zaq.Engine.Workflows.FactLookup` — the same cascade-aware
  resolver edges use — so besides plain top-level keys a `"key"` may reference a
  node-qualified result (`"store_context.record.id"`) or the persistent trigger
  namespace (`"start.company website"`). Both atom and string key forms resolve, so
  the tool works against in-memory and JSONB-rehydrated facts transparently.

  ## Example

      input:      %{active: true, flagged: false, name: "John"}
      conditions: [%{"key" => "active", "value" => true},
                   %{"key" => "flagged", "value" => false}]
      → %{passed: true, input: %{active: true, flagged: false, name: "John"}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "condition",
    description: "Checks that all key/value conditions hold on an input map.",
    schema: [
      input: [
        type: :map,
        required: true,
        doc:
          "Map to evaluate conditions against. Normally delivered by the upstream node " <>
            "or by Batch/Iterate (this is the batch delivery field). When absent — e.g. a " <>
            "Condition that is the first node off a trigger — `run/2` falls back to the " <>
            "incoming fact at root; `start.<field>` dotted keys reach the trigger payload."
      ],
      conditions: [
        type: {:list, :map},
        required: false,
        default: [],
        doc:
          ~s(List of conditions. Each must have "key" and "value"; optional "op" defaults to "eq". Supported ops: eq, neq, gt, lt, gte, lte, not_empty, empty, in.)
      ],
      on_fail: [
        type: {:in, [:halt, :continue]},
        required: false,
        default: :halt,
        doc:
          ":halt returns an error (stops the workflow); :continue returns ok with passed: false."
      ]
    ],
    output_schema: [
      passed: [type: :boolean, required: true, doc: "true if all conditions matched."],
      input: [
        type: :map,
        required: false,
        doc:
          "The original input map, passed through — present only in :halt mode. In :continue " <>
            "(routing) mode it is omitted so it cannot clobber a downstream node's own `input` " <>
            "param; the data stays reachable via cascade (`<node>.input.*`)."
      ],
      failed_conditions: [
        type: {:list, :any},
        required: false,
        doc: "Conditions that did not match. Present only when passed: false (continue mode)."
      ]
    ]

  alias Zaq.Engine.Workflows.EdgeCondition
  alias Zaq.Engine.Workflows.FactLookup

  require Logger

  @impl Jido.Action
  def run(params, context) do
    conditions = Map.get(params, :conditions, [])
    on_fail = normalize_on_fail(Map.get(params, :on_fail))
    input = resolve_input(params)
    eval_map = eval_map(input, context)

    failed = Enum.reject(conditions, &condition_passes?(&1, eval_map))

    Logger.debug("[condition] evaluated",
      run_id: Map.get(context, :run_id),
      step_name: Map.get(context, :step_name),
      failed: length(failed)
    )

    cond do
      # Routing mode (`:continue`) emits ONLY the routing signal. Passing a generic
      # `input` through would clobber a downstream node's own `input` param (e.g.
      # RunAgent's prompt template), since the fact wins on a key collision. The
      # evaluated data stays reachable downstream via cascade (`<node>.input.*`) and
      # the persistent `start.*` namespace — node evaluates, edges route.
      on_fail == :continue ->
        {:ok, routing_result(failed)}

      failed == [] ->
        {:ok, %{passed: true, input: input}}

      true ->
        {:error,
         "Condition not met: " <> Enum.map_join(failed, "; ", &describe_failure(&1, eval_map))}
    end
  end

  defp routing_result([]), do: %{passed: true}
  defp routing_result(failed), do: %{passed: false, failed_conditions: failed}

  # Builds one human-readable clause per failed condition, e.g.
  # `position must equal "CFO" but was "CTO"`. Names the field, what was expected,
  # and the actual value, so the run-view error is self-explanatory.
  defp describe_failure(condition, eval_map) do
    field = get_field(condition, "key") || "field"
    op = (get_field(condition, "op") || "eq") |> to_op()
    expected = get_field(condition, "value")
    phrase(field, op, expected, actual_value(condition, eval_map))
  end

  defp actual_value(condition, eval_map) do
    case FactLookup.fetch(eval_map, get_field(condition, "key")) do
      {:ok, value} -> value
      :error -> get_field(condition, "default")
    end
  end

  defp phrase(field, :not_empty, _expected, _actual), do: "#{field} must not be empty"

  defp phrase(field, :empty, _expected, actual),
    do: "#{field} must be empty but was #{render(actual)}"

  defp phrase(field, op, expected, actual),
    do: "#{field} #{op_phrase(op)} #{render(expected)} but was #{render(actual)}"

  defp op_phrase(:eq), do: "must equal"
  defp op_phrase(:neq), do: "must not equal"
  defp op_phrase(:gt), do: "must be greater than"
  defp op_phrase(:lt), do: "must be less than"
  defp op_phrase(:gte), do: "must be at least"
  defp op_phrase(:lte), do: "must be at most"
  defp op_phrase(:in), do: "must be one of"
  defp op_phrase(op), do: "must satisfy #{op}"

  defp render(nil), do: "empty"
  defp render(value), do: inspect(value)

  # The map to evaluate conditions against:
  #   - an explicit `:input` (mid-DAG: the upstream node produced it), else
  #   - the incoming fact at root (first node off a trigger), minus this action's
  #     own config keys. The persistent `start` namespace rides along in either
  #     case and is reachable via `start.<field>` dotted keys.
  defp resolve_input(params) do
    case Map.fetch(params, :input) do
      {:ok, input} -> input
      :error -> Map.drop(params, [:conditions, :on_fail])
    end
  end

  # The evaluation map is the resolved input augmented with the run's `__cascade__`
  # (handed through `context` by `StepRunner`), so a condition `key` can reference a
  # node-qualified result (`store_context.record.id`) or the persistent `start.*`
  # namespace — not just a top-level key. The original `input` is returned to callers
  # unchanged; only this lookup view carries the cascade.
  defp eval_map(input, context) when is_map(input) do
    case cascade(context) do
      cascade when is_map(cascade) and map_size(cascade) > 0 ->
        Map.put(input, :__cascade__, cascade)

      _ ->
        input
    end
  end

  defp eval_map(input, _context), do: input

  # `context` is always the action context map injected by `StepRunner` (or `%{}`).
  defp cascade(context),
    do: Map.get(context, :__cascade__) || Map.get(context, "__cascade__") || %{}

  # `on_fail` arrives as an atom (direct calls / tests) or a string (authored in
  # JSONB — `DagBuilder.atomize_keys` atomizes keys but leaves values as strings).
  # Accept both; default to `:halt` when absent or unrecognized.
  defp normalize_on_fail(value) when value in [:continue, "continue"], do: :continue
  defp normalize_on_fail(_value), do: :halt

  defp condition_passes?(condition, eval_map) do
    key = get_field(condition, "key")
    value = get_field(condition, "value")
    op = (get_field(condition, "op") || "eq") |> to_op()

    case FactLookup.fetch(eval_map, key) do
      {:ok, actual} ->
        EdgeCondition.evaluate(op, actual, value)

      :error ->
        default = get_field(condition, "default")
        not is_nil(default) and EdgeCondition.evaluate(op, default, value)
    end
  end

  defp get_field(map, string_key) do
    case Map.fetch(map, string_key) do
      {:ok, v} -> v
      :error -> Map.get(map, String.to_existing_atom(string_key))
    end
  rescue
    ArgumentError -> nil
  end

  defp to_op(op) when is_atom(op), do: op
  defp to_op(op) when is_binary(op), do: String.to_existing_atom(op)
end
