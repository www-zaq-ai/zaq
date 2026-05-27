defmodule Zaq.Agent.Tools.Workflow.Condition do
  @moduledoc """
  Checks that all specified key/value conditions hold on an input map.

  If every condition passes, the action returns `{:ok, %{passed: true, input: input}}`.

  When one or more conditions fail the behaviour depends on `on_fail`:

  - `:halt` (default) — returns `{:error, "condition_failed:<keys>"}`
    (e.g. `"condition_failed:active,flagged"`) which stops the workflow step.
  - `:continue` — returns `{:ok, %{passed: false, failed_conditions: [...], input: input}}`
    so downstream steps can branch on the `passed` flag.

  ## Condition format

  Each condition is a map with a `"key"` and `"value"` entry:

      %{"key" => "active", "value" => true}
      %{"key" => "flagged", "value" => false}

  Keys are looked up using both atom and string forms so the tool works with
  atom-keyed or string-keyed maps transparently.

  ## Example

      input:      %{active: true, flagged: false, name: "John"}
      conditions: [%{"key" => "active", "value" => true},
                   %{"key" => "flagged", "value" => false}]
      → %{passed: true, input: %{active: true, flagged: false, name: "John"}}
  """

  use Jido.Action,
    name: "condition",
    description: "Checks that all key/value conditions hold on an input map.",
    schema: [
      input: [
        type: :map,
        required: true,
        doc: "The map to evaluate conditions against."
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
      input: [type: :map, required: true, doc: "The original input map, passed through."],
      failed_conditions: [
        type: :list,
        required: false,
        doc: "Conditions that did not match. Present only when passed: false."
      ]
    ]

  use Zaq.Engine.Workflows.Action

  alias Zaq.Engine.Workflows.EdgeCondition

  require Logger

  @impl Jido.Action
  def run(params, context) do
    input = Map.fetch!(params, :input)
    conditions = Map.get(params, :conditions, [])
    on_fail = Map.get(params, :on_fail, :halt)

    failed = Enum.reject(conditions, &condition_passes?(&1, input))

    Logger.debug("[condition] evaluated",
      run_id: Map.get(context, :run_id),
      step_name: Map.get(context, :step_name),
      failed: length(failed)
    )

    cond do
      failed == [] ->
        {:ok, %{passed: true, input: input}}

      on_fail == :continue ->
        {:ok, %{passed: false, failed_conditions: failed, input: input}}

      true ->
        failed_keys =
          Enum.map_join(failed, ",", fn c ->
            Map.get(c, "key") || Map.get(c, :key) || "unknown"
          end)

        {:error, "condition_failed:#{failed_keys}"}
    end
  end

  defp condition_passes?(condition, input) do
    key = get_field(condition, "key")
    value = get_field(condition, "value")
    op = (get_field(condition, "op") || "eq") |> to_op()

    case fetch_value(input, key) do
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

  # Try string key first, then fall back to atom form (and vice-versa).
  defp fetch_value(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, _} = hit ->
        hit

      :error ->
        atom = String.to_existing_atom(key)
        Map.fetch(map, atom)
    end
  rescue
    ArgumentError -> :error
  end

  defp fetch_value(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, _} = hit -> hit
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end
end
