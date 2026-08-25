defmodule Zaq.Engine.Workflows.Placeholders do
  @moduledoc """
  One `{{...}}` substitution shared by every workflow action that resolves them.

  A placeholder key is whatever `Zaq.Engine.Workflows.FactLookup` resolves: dotted
  segments that may carry spaces or hyphens, so a human-authored sheet header
  (`{{Company Context Content}}`) reads the same as a node-qualified result
  (`{{extract_summary.output}}`) or the trigger namespace (`{{start.language}}`).

  This module owns the *syntax* — the key class, the walk into nested containers,
  and what an unresolved reference collapses to. The *fact* is supplied by
  `Zaq.Engine.Workflows.StepRunner`, which builds one fact for every action: the
  node's own params plus the run cascade. So a bare key names a sibling param and a
  node-qualified key reaches an upstream result, identically whatever the action is.
  """

  alias Zaq.Engine.Workflows.FactLookup

  # Non-greedy + trailing `\s*` keep surrounding padding out of the captured key,
  # and the class never crosses a `}}` boundary.
  @placeholder ~r/\{\{\s*([\w.][\w.\s-]*?)\s*\}\}/
  @sole_placeholder ~r/^\s*\{\{\s*([\w.][\w.\s-]*?)\s*\}\}\s*$/

  @doc """
  Resolves every `{{key}}` in `value` against `fact`.

  Walks maps (values only), lists, and strings; a struct is a domain value, not a
  container, so it is never walked into. An unresolved reference becomes `""` — it
  was being interpolated into a larger string, and nothing renders as nothing.

  With `preserve_type: true`, a string that is *only* a placeholder returns the raw
  resolved value instead of its string form — so a list or map survives as itself,
  and an unresolved one is `nil`. There is no string to interpolate into there, so
  `""` would be a value invented for a reference that found none: an optional field
  wired that way and then omitted would be handed `""`, which its schema refuses for
  any type but a string — a param the run rejects where nothing was supplied at all.
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
  Whether `value` is a string holding exactly one `{{...}}` and nothing else.

  This is the shape `resolve/3` hands back raw under `preserve_type: true`, so it is
  also the shape whose resolved type is the referenced value's own. Anything else —
  an interpolated reference, two references, a plain string, a non-binary — resolves
  to a string whatever the reference holds.
  """
  @spec lone_reference?(term()) :: boolean()
  def lone_reference?(value) when is_binary(value), do: Regex.match?(@sole_placeholder, value)
  def lone_reference?(_value), do: false

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
      [_full, key] -> lookup(fact, key, nil)
      _ -> substitute(string, fact)
    end
  end

  defp substitute(string, fact),
    do: Regex.replace(@placeholder, string, fn _full, key -> stringify(lookup(fact, key)) end)

  # `__cascade__` and friends sit at the fact root because `FactLookup` needs them
  # there, but they are engine plumbing — never a variable an author may print.
  # `FactLookup` already refuses to fuzzy-match them; this refuses them outright.
  # `unresolved` is what a reference that finds nothing becomes, and it differs by
  # caller: `""` when the value is being rendered into a larger string, `nil` when it
  # *is* the value.
  defp lookup(fact, key, unresolved \\ "")

  defp lookup(_fact, "__" <> _reserved, unresolved), do: unresolved

  defp lookup(fact, key, unresolved) when is_binary(key) do
    case FactLookup.fetch(fact, key) do
      {:ok, value} -> value
      :error -> unresolved
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
