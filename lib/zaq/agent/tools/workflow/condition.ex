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

  Each condition is a map with a `"key"` and `"value"` entry, plus an optional
  `"op"` (defaults to `"eq"`) and optional `"type"`:

      %{"key" => "active", "value" => true}
      %{"key" => "flagged", "value" => false}

  ## Date conditions

  Set `"type" => "date"` or `"type" => "datetime"` to compare `%Date{}` /
  `%DateTime{}` values chronologically (via `Zaq.Engine.Workflows.EdgeCondition`
  / `DateOperand`) instead of by term order. The `"value"` accepts an ISO8601
  string, a sentinel (`"today"` / `"now"`), or a relative map — so "last email
  older than 7 days" is:

      %{"key" => "last_sent_at", "type" => "datetime", "op" => "lt",
        "value" => %{"from" => "now", "days" => -7}}

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
        type: {:or, [{:map, :any, :any}, :string]},
        required: true,
        doc:
          "Map to evaluate conditions against. Normally delivered by the upstream node " <>
            "or by Batch/Iterate (this is the batch delivery field). May also be a dotted " <>
            "reference string (e.g. \"build_history.metadata\") resolved against the run " <>
            "cascade — useful because node params are not engine-resolved and a Condition " <>
            "must keep its own `input` to fire. Input is required, including trigger-first " <>
            "conditions: use an explicit map or a reference such as `start`. " <>
            "Unresolved or non-map references are validation errors."
      ],
      conditions: [
        type: {:list, {:map, :any, :any}},
        required: false,
        default: [],
        doc:
          ~s|List of conditions. Each must have "key" and "value"; optional "op" defaults to "eq". Supported ops: eq, neq, gt, lt, gte, lte, not_empty, empty, in. Optional "type" ("date"/"datetime") compares chronologically; "value" then accepts an ISO8601 string, "today"/"now", or a relative map like %{"from" => "now", "days" => -7}.|
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
        type: {:map, :any, :any},
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

  alias Jido.Action.Error
  alias Zaq.Engine.Workflows.EdgeCondition
  alias Zaq.Engine.Workflows.FactLookup

  require Logger

  @impl Jido.Action
  def on_before_validate_params(params) do
    Enum.reduce_while([:input, :conditions, :on_fail], {:ok, params}, fn key, {:ok, acc} ->
      normalize_param(acc, key)
    end)
  end

  defp normalize_param(params, key) do
    string_key = Atom.to_string(key)
    atom_value = normalize_value(key, Map.get(params, key))
    string_value = normalize_value(key, Map.get(params, string_key))

    cond do
      Map.has_key?(params, key) and Map.has_key?(params, string_key) and
          atom_value != string_value ->
        {:halt, {:error, Error.validation_error("Conflicting #{key} aliases")}}

      Map.has_key?(params, key) ->
        {:cont, {:ok, params |> Map.delete(string_key) |> Map.put(key, atom_value)}}

      Map.has_key?(params, string_key) ->
        {:cont, {:ok, params |> Map.delete(string_key) |> Map.put(key, string_value)}}

      true ->
        {:cont, {:ok, params}}
    end
  end

  defp normalize_value(:on_fail, "halt"), do: :halt
  defp normalize_value(:on_fail, "continue"), do: :continue
  defp normalize_value(_key, value), do: value

  @impl Jido.Action
  def run(params, context) do
    with {:ok, input} <- resolve_input(params, context) do
      evaluate_conditions(params, context, input)
    end
  end

  defp evaluate_conditions(params, context, input) do
    conditions = Map.get(params, :conditions, [])
    on_fail = normalize_value(:on_fail, Map.get(params, :on_fail, :halt))
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
        message =
          "Condition not met: " <> Enum.map_join(failed, "; ", &describe_failure(&1, eval_map))

        {:error, Error.execution_error(message, %{retry: false})}
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
    type = get_field(condition, "type")
    expected = get_field(condition, "value")
    actual = actual_value(condition, eval_map)

    if type in ["date", "datetime"] and op not in [:empty, :not_empty] do
      "#{field} #{date_op_phrase(op)} #{render(expected)} but was #{render(actual)}"
    else
      phrase(field, op, expected, actual)
    end
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

  # Date/datetime conditions read more naturally as before/after than gt/lt.
  defp date_op_phrase(:eq), do: "must be"
  defp date_op_phrase(:neq), do: "must not be"
  defp date_op_phrase(:gt), do: "must be after"
  defp date_op_phrase(:lt), do: "must be before"
  defp date_op_phrase(:gte), do: "must be on or after"
  defp date_op_phrase(:lte), do: "must be on or before"
  defp date_op_phrase(op), do: op_phrase(op)

  defp render(nil), do: "empty"
  defp render(value), do: inspect(value)

  # The map to evaluate conditions against:
  #   - an explicit `:input` map (mid-DAG: the upstream node delivered it), used as-is;
  #   - an explicit `:input` **string** — a dotted reference (e.g.
  #     `"build_history.metadata"`) resolved against the run cascade. Node params are
  #     NOT resolved by the engine (only edge mappings are), and a Condition must keep
  #     its own `input` param to be scheduled/fire, so a reference authored on the node
  #     lands here as a raw string; resolve it so keys read the real map instead of
  #     missing against the bare string (which pins `passed` to false);
  # Missing input and references to non-map data are deliberate validation errors.
  # The persistent `start` namespace rides along via the cascade in every case and is
  # reachable through `start.<field>` dotted keys.
  defp resolve_input(params, context) do
    case Map.fetch(params, :input) do
      {:ok, ref} when is_binary(ref) ->
        resolve_reference(ref, context)

      {:ok, input} when is_map(input) ->
        {:ok, input}

      _ ->
        {:error,
         Error.validation_error("Condition input must be an explicit map or map reference")}
    end
  end

  # Resolve input using the same shared cascade lookup as edge conditions.
  defp resolve_reference(ref, context) do
    case FactLookup.fetch(cascade(context), ref) do
      {:ok, value} when is_map(value) ->
        {:ok, value}

      _ ->
        {:error,
         Error.validation_error("Condition input reference must resolve to a map", %{
           reference: ref
         })}
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

  defp condition_passes?(condition, eval_map) do
    key = get_field(condition, "key")
    value = get_field(condition, "value")
    op = (get_field(condition, "op") || "eq") |> to_op()
    opts = [type: get_field(condition, "type")]

    case FactLookup.fetch(eval_map, key) do
      {:ok, actual} ->
        EdgeCondition.evaluate(op, actual, value, opts)

      :error ->
        default = get_field(condition, "default")
        not is_nil(default) and EdgeCondition.evaluate(op, default, value, opts)
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
