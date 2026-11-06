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

  `"op"` and `"type"` are validated against the supported sets
  (`Zaq.Engine.Workflows.EdgeCondition.ops/0` and `"date"`/`"datetime"`), so an
  unsupported operator is an input validation error rather than a runtime failure.
  An optional `"default"` supplies the actual value when the key is absent from the
  input. Condition maps may be authored with string or atom keys; atom `"key"`,
  `"op"` and `"type"` values are normalized to their string form before validation.

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

  @condition_ops Enum.map(Zaq.Engine.Workflows.EdgeCondition.ops(), &to_string/1)
  @condition_types ~w(date datetime)
  @on_fail_modes ~w(halt continue)
  @condition_string_fields [{"key", :key}, {"op", :op}, {"type", :type}]

  # Condition objects arrive string-keyed from JSONB and from LLM tool arguments, and
  # atom-keyed from in-code callers; `coerce: true` accepts both and settles on the
  # string form. Unknown keys are preserved so an authored condition never loses data.
  @condition_schema Zoi.object(
                      %{
                        "key" =>
                          Zoi.string(
                            description:
                              "Fact key to read. Resolved through the run cascade, so a " <>
                                "node-qualified path (\"store_context.record.id\") or the " <>
                                "persistent trigger namespace (\"start.position\") also works."
                          ),
                        "value" =>
                          Zoi.any(
                            description:
                              "Expected value. For date/datetime conditions this accepts an " <>
                                ~s|ISO8601 string, "today"/"now", or a relative object such | <>
                                ~s|as {"from": "now", "days": -7}.|
                          )
                          |> Zoi.optional(),
                        "op" =>
                          Zoi.enum(@condition_ops,
                            description: "Comparison operator. Defaults to eq."
                          )
                          |> Zoi.optional(),
                        "type" =>
                          Zoi.enum(@condition_types,
                            description:
                              "Compare the operands chronologically instead of by term order."
                          )
                          |> Zoi.optional(),
                        "default" =>
                          Zoi.any(
                            description:
                              "Actual value to evaluate when the key is absent from the input."
                          )
                          |> Zoi.optional()
                      },
                      coerce: true,
                      unrecognized_keys: :preserve,
                      description: "A single key/value condition."
                    )

  use Zaq.Engine.Workflows.Action,
    name: "condition",
    description: "Checks that all key/value conditions hold on an input map.",
    schema:
      Zoi.object(
        %{
          input:
            Zoi.union([Zoi.map(Zoi.any(), Zoi.any()), Zoi.string()],
              description:
                "Map to evaluate conditions against. Normally delivered by the upstream node " <>
                  "or by Batch/Iterate (this is the batch delivery field). May also be a dotted " <>
                  "reference string (e.g. \"build_history.metadata\") resolved against the run " <>
                  "cascade — useful because node params are not engine-resolved and a Condition " <>
                  "must keep its own `input` to fire. Input is required, including trigger-first " <>
                  "conditions: use an explicit map or a reference such as `start`. " <>
                  "Unresolved or non-map references are validation errors."
            ),
          conditions:
            Zoi.list(@condition_schema,
              description:
                "List of conditions. Each must have a \"key\"; \"op\" defaults to \"eq\"."
            )
            |> Zoi.default([])
            |> Zoi.optional(),
          on_fail:
            Zoi.enum(@on_fail_modes,
              description:
                "halt returns an error (stops the workflow); continue returns ok with passed: false."
            )
            |> Zoi.default("halt")
            |> Zoi.optional()
        },
        coerce: true,
        unrecognized_keys: :preserve
      ),
    output_schema:
      Zoi.object(%{
        passed: Zoi.boolean(description: "true if all conditions matched."),
        input:
          Zoi.map(Zoi.any(), Zoi.any(),
            description:
              "The original input map, passed through — present only in :halt mode. In :continue " <>
                "(routing) mode it is omitted so it cannot clobber a downstream node's own `input` " <>
                "param; the data stays reachable via cascade (`<node>.input.*`)."
          )
          |> Zoi.optional(),
        failed_conditions:
          Zoi.list(@condition_schema,
            description:
              "Conditions that did not match. Present only when passed: false (continue mode)."
          )
          |> Zoi.optional()
      })

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
    forms = {Map.has_key?(params, key), Map.has_key?(params, string_key)}

    case validate_param(key, forms, atom_value, string_value) do
      :ok ->
        {:cont, {:ok, put_param(params, key, string_key, forms, atom_value, string_value)}}

      {:error, error} ->
        {:halt, {:error, error}}
    end
  end

  defp validate_param(key, {true, true}, atom_value, string_value)
       when atom_value != string_value,
       do: {:error, Error.validation_error("Conflicting #{key} aliases")}

  # `Zoi.default/2` short-circuits an explicit `nil` to the default value, so an
  # authored null would silently become `[]` / `"halt"`. Keep it the validation error
  # it has always been.
  defp validate_param(key, forms, nil, nil)
       when key in [:conditions, :on_fail] and forms != {false, false},
       do: {:error, Error.validation_error("#{key} must not be null")}

  defp validate_param(_key, _forms, _atom_value, _string_value), do: :ok

  defp put_param(params, key, string_key, {true, _}, atom_value, _string_value),
    do: params |> Map.delete(string_key) |> Map.put(key, atom_value)

  defp put_param(params, key, string_key, {false, true}, _atom_value, string_value),
    do: params |> Map.delete(string_key) |> Map.put(key, string_value)

  defp put_param(params, _key, _string_key, {false, false}, _atom_value, _string_value),
    do: params

  # The schema publishes the string forms, so callers that hand atoms (`:continue`,
  # `op: :eq`, `key: :active`) are normalized to strings *before* validation; `run/2`
  # converts back to atoms where evaluation needs them.
  defp normalize_value(:on_fail, mode) when is_atom(mode) and not is_nil(mode),
    do: Atom.to_string(mode)

  defp normalize_value(:conditions, conditions) when is_list(conditions),
    do: Enum.map(conditions, &normalize_condition/1)

  defp normalize_value(_key, value), do: value

  defp normalize_condition(condition) when is_map(condition),
    do: Enum.reduce(@condition_string_fields, condition, &stringify_condition_field(&2, &1))

  defp normalize_condition(condition), do: condition

  defp stringify_condition_field(condition, {string_key, atom_key}) do
    cond do
      Map.has_key?(condition, string_key) ->
        Map.update!(condition, string_key, &stringify_atom/1)

      Map.has_key?(condition, atom_key) ->
        Map.update!(condition, atom_key, &stringify_atom/1)

      true ->
        condition
    end
  end

  defp stringify_atom(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp stringify_atom(value), do: value

  @impl Jido.Action
  def run(params, context) do
    with {:ok, input} <- resolve_input(params, context) do
      evaluate_conditions(params, context, input)
    end
  end

  defp evaluate_conditions(params, context, input) do
    conditions = Map.get(params, :conditions, [])
    routing? = Map.get(params, :on_fail, "halt") in ["continue", :continue]
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
      routing? ->
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
