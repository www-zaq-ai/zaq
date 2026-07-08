defmodule Zaq.Agent.Tools.Workflow.Split do
  @moduledoc """
  Splits a string into two parts on the **first** occurrence of a separator.

  A generic text utility for workflow DAGs: given `text` and a `separator`, returns
  `%{before: ..., after: ...}` where `before` is everything up to the first
  `separator` and `after` is everything past it. Both sides are trimmed. When the
  separator is not found, `before` is the whole (trimmed) text and `after` is `""`.

  Common uses: peeling a header/first line off a body, taking the value after a
  label, splitting a `"key<sep>value"` pair, isolating the first paragraph, etc.

  ## Example

      iex> Zaq.Agent.Tools.Workflow.Split.run(%{text: "first line\\nthe rest", separator: "\\n"}, %{})
      {:ok, %{before: "first line", after: "the rest"}}

      iex> Zaq.Agent.Tools.Workflow.Split.run(%{text: "role=admin", separator: "="}, %{})
      {:ok, %{before: "role", after: "admin"}}

      iex> Zaq.Agent.Tools.Workflow.Split.run(%{text: "no separator here", separator: "\\n"}, %{})
      {:ok, %{before: "no separator here", after: ""}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "split",
    description: "Split text into before/after on the first occurrence of a separator.",
    schema: [
      text: [type: :string, required: true, doc: "The text to split."],
      separator: [
        type: :string,
        required: true,
        doc: "Substring to split on. Only the first occurrence is used."
      ]
    ],
    output_schema: [
      before: [type: :string, required: true, doc: "Text before the first separator (trimmed)."],
      after: [
        type: :string,
        required: true,
        doc: "Text after the first separator (trimmed); \"\" when the separator is absent."
      ]
    ]

  @impl Jido.Action
  def run(params, _context) do
    text = get(params, :text) || ""
    separator = get(params, :separator) || ""
    {:ok, split(text, separator)}
  end

  # Accept atom- or string-keyed params (in-process vs JSONB-rehydrated).
  defp get(params, key), do: Map.get(params, key) || Map.get(params, to_string(key))

  # An empty separator has no meaningful split point; treat the whole text as `before`.
  defp split(text, ""), do: %{before: String.trim(text), after: ""}

  defp split(text, separator) do
    case String.split(text, separator, parts: 2) do
      [before, rest] -> %{before: String.trim(before), after: String.trim(rest)}
      [only] -> %{before: String.trim(only), after: ""}
    end
  end
end
