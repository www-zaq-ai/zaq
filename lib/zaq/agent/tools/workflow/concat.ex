defmodule Zaq.Agent.Tools.Workflow.Concat do
  @moduledoc """
  Generic string concatenation action for workflow DAGs.

  Joins `parts` (in order) with an optional `separator`, returning the joined
  string as `result`. Each part is coerced to a string, and `{{key}}`
  placeholders inside a part are substituted with the value of that key from the
  action's other input params — the same `{{variable}}` convention used by
  `Zaq.Agent.Tools.Workflow.RunAgent`.

  Because the workflow `StepRunner` merges a node's static `params` with the
  values delivered through incoming edge `mapping`s before calling `run/2`, a
  placeholder can reference either a static param or a value mapped in from an
  upstream node. This is what lets a single generic concat build a value that
  mixes fixed text with dynamic upstream data — e.g. an A1 cell range:

      params:  %{"parts" => ["Sheet1!{{column}}{{row}}"], "column" => "J"}
      mapping: %{"row" => "increment_email_state.value"}
      # => %{result: "Sheet1!J5"}

  ## Examples

      iex> Zaq.Agent.Tools.Workflow.Concat.run(%{parts: ["a", "b", "c"]}, %{})
      {:ok, %{result: "abc"}}

      iex> Zaq.Agent.Tools.Workflow.Concat.run(%{parts: ["x", "y"], separator: "-"}, %{})
      {:ok, %{result: "x-y"}}

      iex> Zaq.Agent.Tools.Workflow.Concat.run(%{parts: ["{{column}}{{row}}"], column: "J", row: 5}, %{})
      {:ok, %{result: "J5"}}

      # `as_matrix` also returns the result wrapped as a 1x1 matrix, ready to
      # feed range-mode UpdateSheetValues `values`.
      iex> Zaq.Agent.Tools.Workflow.Concat.run(%{parts: ["{{value}}"], value: 3, as_matrix: true}, %{})
      {:ok, %{result: "3", matrix: [["3"]]}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "concat",
    description:
      "Join parts into a single string with an optional separator, substituting {{key}} placeholders from other input params.",
    schema: [
      parts: [
        type: {:list, :any},
        required: true,
        doc:
          "Values joined in order. Each is coerced to a string; {{key}} placeholders inside a part are substituted from the other input params."
      ],
      separator: [type: :string, required: false, default: "", doc: "Inserted between parts."],
      as_matrix: [
        type: :boolean,
        required: false,
        default: false,
        doc: "When true, also return the result wrapped as a 1x1 matrix under `matrix`."
      ]
    ],
    output_schema: [
      result: [type: :string, required: true, doc: "The concatenated string."],
      matrix: [
        type: {:list, {:list, :any}},
        required: false,
        doc: "The result wrapped as [[result]]; present only when `as_matrix` is true."
      ]
    ]

  @reserved_keys [:parts, :separator, :as_matrix, "parts", "separator", "as_matrix"]
  @placeholder ~r/\{\{\s*([\w.]+)\s*\}\}/

  @impl Jido.Action
  def run(params, _context) do
    parts = Map.get(params, :parts, Map.get(params, "parts"))

    case parts do
      list when is_list(list) ->
        separator = Map.get(params, :separator, Map.get(params, "separator")) || ""
        vars = Map.drop(params, @reserved_keys)
        result = Enum.map_join(list, separator, &substitute(&1, vars))

        if truthy?(Map.get(params, :as_matrix, Map.get(params, "as_matrix"))) do
          {:ok, %{result: result, matrix: [[result]]}}
        else
          {:ok, %{result: result}}
        end

      _ ->
        {:error, "concat requires a list of parts, got: #{inspect(parts)}"}
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp substitute(part, vars) do
    Regex.replace(@placeholder, to_string(part), fn _full, key ->
      vars |> lookup(key) |> to_string()
    end)
  end

  defp lookup(vars, key) do
    case Map.get(vars, key) do
      nil -> Map.get(vars, safe_atom(key), "")
      value -> value
    end
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
