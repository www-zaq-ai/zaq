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
      input: [type: :map, required: true, doc: "The original input map, passed through."],
      failed_conditions: [
        type: {:list, :any},
        required: false,
        doc: "Conditions that did not match. Present only when passed: false."
      ]
    ]

  alias Zaq.Engine.Workflows.EdgeCondition

  require Logger

  @impl Jido.Action
  def run(params, context) do
    conditions = Map.get(params, :conditions, [])
    on_fail = Map.get(params, :on_fail, :halt)
    input = resolve_input(params)

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

  # A dotted key (e.g. "start.position") traverses namespaces in the eval map:
  # each segment is looked up with atom/string fallback, descending into nested
  # maps. A plain key is looked up directly (string first, then atom form).
  defp fetch_value(map, key) when is_binary(key) do
    if String.contains?(key, ".") do
      fetch_path(map, String.split(key, "."))
    else
      fetch_flat(map, key)
    end
  end

  defp fetch_value(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, _} = hit -> hit
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp fetch_path(map, [segment]) when is_map(map), do: fetch_flat(map, segment)

  defp fetch_path(map, [segment | rest]) when is_map(map) do
    case fetch_flat(map, segment) do
      {:ok, sub} -> fetch_path(sub, rest)
      :error -> :error
    end
  end

  defp fetch_path(_non_map, _segments), do: :error

  # Try string key first, then fall back to atom form. Safe when the atom was
  # never interned (e.g. a key string this VM has never seen).
  defp fetch_flat(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, _} = hit -> hit
      :error -> Map.fetch(map, String.to_existing_atom(key))
    end
  rescue
    ArgumentError -> :error
  end

  defp fetch_flat(_non_map, _key), do: :error
end
