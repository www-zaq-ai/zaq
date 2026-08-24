defmodule Zaq.Engine.Workflows.Placeholders do
  @moduledoc """
  One `{{...}}` substitution shared by every workflow action that resolves them.

  A placeholder key is whatever `Zaq.Engine.Workflows.FactLookup` resolves: dotted
  segments that may carry spaces or hyphens, so a human-authored sheet header
  (`{{Company Context Content}}`) reads the same as a node-qualified result
  (`{{extract_summary.output}}`) or the trigger namespace (`{{start.language}}`).

  This module owns the *syntax* — the key class, the walk into nested containers,
  and what an unresolved reference collapses to. Each caller owns the *fact*: what
  a bare key may name is a per-action decision (`Concat` exposes its own params,
  `DispatchEvent` exposes only the cascade), so the fact is passed in rather than
  built here.
  """

  alias Zaq.Engine.Workflows.FactLookup

  # Non-greedy + trailing `\s*` keep surrounding padding out of the captured key,
  # and the class never crosses a `}}` boundary.
  @placeholder ~r/\{\{\s*([\w.][\w.\s-]*?)\s*\}\}/
  @sole_placeholder ~r/^\s*\{\{\s*([\w.][\w.\s-]*?)\s*\}\}\s*$/

  @doc """
  Resolves every `{{key}}` in `value` against `fact`.

  Walks maps (values only), lists, and strings; a struct is a domain value, not a
  container, so it is never walked into. An unresolved reference becomes `""`.

  With `preserve_type: true`, a string that is *only* a placeholder returns the raw
  resolved value instead of its string form — so a list or map survives as itself.
  """
  @spec resolve(term(), map(), keyword()) :: term()
  def resolve(value, fact, opts \\ [])

  def resolve(value, _fact, _opts) when is_struct(value), do: value

  def resolve(map, fact, opts) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, resolve(v, fact, opts)} end)

  def resolve(list, fact, opts) when is_list(list),
    do: Enum.map(list, &resolve(&1, fact, opts))

  def resolve(string, fact, opts) when is_binary(string) do
    if Keyword.get(opts, :preserve_type, false) do
      substitute_preserving_type(string, fact)
    else
      substitute(string, fact)
    end
  end

  def resolve(other, _fact, _opts), do: other

  @doc """
  Every `{{key}}` reference inside `value`, in order, with duplicates kept.

  Walks the same containers `resolve/3` does, so what this reports is exactly what
  that would look up. Reserved `__*` keys are omitted — `resolve/3` refuses them, so
  they are not references anything can satisfy.

  Read-only: unlike `resolve/3` it never rebuilds the term, which is what makes it
  cheap enough to scan a node's params at DAG-build time.
  """
  @spec references(term()) :: [String.t()]
  def references(value) when is_struct(value), do: []

  def references(map) when is_map(map),
    do: Enum.flat_map(map, fn {_k, v} -> references(v) end)

  def references(list) when is_list(list), do: Enum.flat_map(list, &references/1)

  def references(string) when is_binary(string) do
    @placeholder
    |> Regex.scan(string)
    |> Enum.map(fn [_full, key] -> key end)
    |> Enum.reject(&String.starts_with?(&1, "__"))
  end

  def references(_other), do: []

  # A whole-string placeholder keeps the raw value; an embedded one is stringified.
  defp substitute_preserving_type(string, fact) do
    case Regex.run(@sole_placeholder, string) do
      [_full, key] -> lookup(fact, key)
      _ -> substitute(string, fact)
    end
  end

  defp substitute(string, fact),
    do: Regex.replace(@placeholder, string, fn _full, key -> stringify(lookup(fact, key)) end)

  # `__cascade__` and friends sit at the fact root because `FactLookup` needs them
  # there, but they are engine plumbing — never a variable an author may print.
  # `FactLookup` already refuses to fuzzy-match them; this refuses them outright.
  defp lookup(_fact, "__" <> _reserved), do: ""

  defp lookup(fact, key) when is_binary(key) do
    case FactLookup.fetch(fact, key) do
      {:ok, value} -> value
      :error -> ""
    end
  end

  # Scalars render as themselves; anything else is inspected rather than raising
  # (`to_string/1` has no implementation for a map and silently turns a list into
  # its binary form).
  defp stringify(value) when is_binary(value), do: value
  defp stringify(nil), do: ""
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_float(value), do: Float.to_string(value)
  defp stringify(value) when is_boolean(value), do: to_string(value)
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: inspect(value)
end
