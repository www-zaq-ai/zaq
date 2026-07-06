defmodule Zaq.Agent.Tools.Workflow.Concat do
  @moduledoc """
  Generic concatenation action for workflow DAGs — joins `parts` into a **string**
  or, when any part is (or resolves to) a list, concatenates them into a **list**.

  ## Placeholder substitution

  `{{key}}` placeholders inside a part are substituted with the value of that key,
  resolved through `Zaq.Engine.Workflows.FactLookup` — the same cascade-aware
  resolver edges and the `Condition` node use. So a `key` may reference a local
  input param, a node-qualified upstream result (`build_history.conversations`),
  or the persistent trigger namespace (`start.summary`). Local params take
  precedence for plain (dotless) keys.

  Because the workflow `StepRunner` merges a node's static `params` with the values
  delivered through incoming edge `mapping`s (and passes the run's `__cascade__` in
  `context`) before calling `run/2`, a placeholder can reference static params,
  mapped-in values, or any prior node's output.

  A placeholder that is the **whole** string (`"{{key}}"`) is replaced with the
  **raw** resolved value — preserving its type, so a list or map stays a list or
  map. A placeholder **embedded** in other text is stringified. Substitution
  descends into nested lists and maps, so placeholders inside a message array's
  `content` are resolved in place. Structs (e.g. `%DateTime{}`) are treated as
  opaque leaves and never walked into.

  ## Output shape

  - **String mode** (no part is a list): `%{result: <string>}`, plus
    `matrix: [[result]]` when `as_matrix: true`.
  - **List mode** (auto-detected — any resolved part is a list): `%{list: <list>}`.
    Each part is normalised to a list (a non-list part is wrapped as `[part]`) and
    the parts are concatenated in order. `separator` and `as_matrix` do not apply.

  ## Examples

      iex> Zaq.Agent.Tools.Workflow.Concat.run(%{parts: ["a", "b", "c"]}, %{})
      {:ok, %{result: "abc"}}

      iex> Zaq.Agent.Tools.Workflow.Concat.run(%{parts: ["x", "y"], separator: "-"}, %{})
      {:ok, %{result: "x-y"}}

      iex> Zaq.Agent.Tools.Workflow.Concat.run(%{parts: ["{{column}}{{row}}"], column: "J", row: 5}, %{})
      {:ok, %{result: "J5"}}

      # List mode: concatenate two lists.
      iex> Zaq.Agent.Tools.Workflow.Concat.run(%{parts: [[1, 2], [3, 4]]}, %{})
      {:ok, %{list: [1, 2, 3, 4]}}

      # `as_matrix` returns the result wrapped as a 1x1 matrix (string mode only).
      iex> Zaq.Agent.Tools.Workflow.Concat.run(%{parts: ["{{value}}"], value: 3, as_matrix: true}, %{})
      {:ok, %{result: "3", matrix: [["3"]]}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "concat",
    description:
      "Join parts into a single string, or concatenate them into a list when any part is a list. {{key}} placeholders are resolved cascade-aware; a whole-string placeholder keeps the raw value's type.",
    schema: [
      parts: [
        type: {:list, :any},
        required: true,
        doc:
          "Values joined/concatenated in order. Each may contain {{key}} placeholders resolved from params or the run cascade. If any part is (or resolves to) a list, the action returns a concatenated list instead of a joined string."
      ],
      separator: [
        type: :string,
        required: false,
        default: "",
        doc: "Inserted between parts in string mode. Ignored in list mode."
      ],
      as_matrix: [
        type: :boolean,
        required: false,
        default: false,
        doc:
          "String mode only: when true, also return the result wrapped as a 1x1 matrix under `matrix`."
      ]
    ],
    output_schema: [
      result: [
        type: :string,
        required: false,
        doc: "The concatenated string. Present in string mode only."
      ],
      list: [
        type: {:list, :any},
        required: false,
        doc: "The concatenated list. Present in list mode only (any part is a list)."
      ],
      matrix: [
        type: {:list, {:list, :any}},
        required: false,
        doc:
          "The result wrapped as [[result]]; present only when `as_matrix` is true (string mode)."
      ]
    ]

  alias Zaq.Engine.Workflows.FactLookup

  @reserved_keys [:parts, :separator, :as_matrix, "parts", "separator", "as_matrix"]
  @placeholder ~r/\{\{\s*([\w.]+)\s*\}\}/
  @sole_placeholder ~r/^\s*\{\{\s*([\w.]+)\s*\}\}\s*$/

  @impl Jido.Action
  def run(params, context) do
    parts = Map.get(params, :parts, Map.get(params, "parts"))

    case parts do
      list when is_list(list) ->
        fact = lookup_fact(params, context)
        resolved = Enum.map(list, &resolve_part(&1, fact))

        if Enum.any?(resolved, &is_list/1) do
          {:ok, %{list: concat_lists(resolved)}}
        else
          string_result(resolved, params)
        end

      _ ->
        {:error, "concat requires a list of parts, got: #{inspect(parts)}"}
    end
  end

  # ── String mode ──────────────────────────────────────────────────────────────

  defp string_result(resolved, params) do
    separator = Map.get(params, :separator, Map.get(params, "separator")) || ""
    result = Enum.map_join(resolved, separator, &to_string/1)

    if truthy?(Map.get(params, :as_matrix, Map.get(params, "as_matrix"))) do
      {:ok, %{result: result, matrix: [[result]]}}
    else
      {:ok, %{result: result}}
    end
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  # ── List mode ────────────────────────────────────────────────────────────────

  defp concat_lists(resolved) do
    resolved
    |> Enum.map(fn
      part when is_list(part) -> part
      part -> [part]
    end)
    |> Enum.concat()
  end

  # ── Cascade-aware, type-preserving substitution ──────────────────────────────

  # The lookup fact is the node's non-reserved params augmented with the run's
  # `__cascade__` (handed through `context` by `StepRunner`), so a `{{key}}` can
  # reference a plain param, a node-qualified result, or the `start.*` namespace.
  defp lookup_fact(params, context) do
    params
    |> Map.drop(@reserved_keys)
    |> Map.put(:__cascade__, cascade(context))
  end

  defp cascade(context),
    do: Map.get(context, :__cascade__) || Map.get(context, "__cascade__") || %{}

  # A struct is a domain value, not a container — never walk into it.
  defp resolve_part(part, _fact) when is_struct(part), do: part
  defp resolve_part(part, fact) when is_list(part), do: Enum.map(part, &resolve_part(&1, fact))

  defp resolve_part(part, fact) when is_map(part),
    do: Map.new(part, fn {k, v} -> {k, resolve_part(v, fact)} end)

  defp resolve_part(part, fact) when is_binary(part), do: substitute_string(part, fact)
  defp resolve_part(part, _fact), do: part

  # A whole-string placeholder keeps the raw resolved value (type preserved); an
  # embedded placeholder is stringified in place.
  defp substitute_string(str, fact) do
    case Regex.run(@sole_placeholder, str) do
      [_full, key] ->
        lookup(fact, key)

      _ ->
        Regex.replace(@placeholder, str, fn _full, key -> to_string(lookup(fact, key)) end)
    end
  end

  defp lookup(fact, key) do
    case FactLookup.fetch(fact, key) do
      {:ok, value} -> value
      :error -> ""
    end
  end
end
