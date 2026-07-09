defmodule Zaq.Engine.Workflows.FactLookup do
  @moduledoc """
  Single cascade-aware field resolver shared by edge routing (`Steps.EdgeStep`)
  and node evaluation (`Zaq.Agent.Tools.Workflow.Condition`).

  A workflow fact is an atom/string-keyed map that may carry a `:__cascade__`
  namespace — a map of `step_name => step_result` accumulated by `StepRunner`,
  with the trigger payload planted under `:start`. `fetch/2` resolves a field
  reference against that fact and returns `{:ok, value}` or `:error`, so callers
  can distinguish an absent key (apply a default, take the other branch) from a
  present `nil`/`false` value.

  ## Key forms

  | Reference          | Resolves to                                          |
  |--------------------|------------------------------------------------------|
  | `"field"`          | top-level fact key                                   |
  | `"step.field"`     | `__cascade__[step][field]` (node-qualified)          |
  | `"step.a.b…"`      | descends the cascade step result by each segment     |
  | `"a.b…"`           | when `a` is not a cascade step, descends the fact     |

  A dotted reference is resolved cascade-first: if the leading segment names a
  step in `__cascade__`, the remaining segments descend that step's result;
  otherwise the whole path descends the fact itself (plain nested maps). Both the
  step name and every segment are looked up with an atom-then-string fallback, so
  references resolve whether the run is in memory (atom keys) or was rehydrated
  from JSONB (string keys).

  ## Format-insensitive fallback

  Each segment is resolved by an **exact** match first; if that misses, it falls
  back to a **canonicalized** match that ignores case and treats runs of spaces,
  underscores, and hyphens as one separator (after trimming). So a reference like
  `"company context content"` resolves a key stored as `"Company Context Content"`,
  `"company_context_content"`, or `"company context content "` — the mismatch
  class that arises from human-authored sheet headers — without any action having
  to canonicalize keys. Exact matches always win, so this never changes the result
  for references that already resolve, and reserved internal keys (`__*`) never
  fuzzy-match. It does **not** bridge genuinely different words (e.g. `content` vs
  `file`).

  If two or more stored keys canonicalize identically to the reference and hold
  **different** values (e.g. a fact carrying both `"company context"` and
  `"company_context"`), the fallback refuses to guess: it logs a warning and
  reports `:error` (an unresolved reference) rather than silently returning
  whichever key the map happened to enumerate first. Exact matches are never
  affected, and identical values under several canonically-equal keys resolve
  normally.
  """

  require Logger

  @cascade_keys [:__cascade__, "__cascade__"]

  @doc """
  Resolves `key` against `fact`, returning `{:ok, value}` or `:error`.

  `key` is a string field reference (optionally dotted, see the module doc) or an
  atom top-level key. A non-map `fact` always returns `:error`.
  """
  @spec fetch(term(), String.t() | atom()) :: {:ok, term()} | :error
  def fetch(fact, key) when is_map(fact) and is_binary(key) do
    case String.split(key, ".") do
      [simple] -> flat_fetch(fact, simple)
      [step | rest] -> fetch_dotted(fact, step, rest)
    end
  end

  def fetch(fact, key) when is_map(fact) and is_atom(key),
    do: flat_fetch(fact, Atom.to_string(key))

  def fetch(_fact, _key), do: :error

  # Cascade-first: a leading segment that names a `__cascade__` step descends that
  # step's result; otherwise the whole path descends the fact (plain nested maps).
  defp fetch_dotted(fact, step, rest) do
    case cascade_step(fact, step) do
      {:ok, step_result} -> descend(step_result, rest)
      :error -> descend(fact, [step | rest])
    end
  end

  defp cascade_step(fact, step) do
    cascade = Enum.find_value(@cascade_keys, %{}, &Map.get(fact, &1))
    if is_map(cascade), do: flat_fetch(cascade, step), else: :error
  end

  defp descend(value, []), do: {:ok, value}

  defp descend(map, [segment | rest]) when is_map(map) do
    case flat_fetch(map, segment) do
      {:ok, sub} -> descend(sub, rest)
      :error -> :error
    end
  end

  defp descend(_non_map, _segments), do: :error

  # Resolve a single segment: try an exact match first, then fall back to a
  # normalized match. Exact always wins, so already-matching workflows are
  # unaffected; the fallback only rescues references whose formatting differs
  # from the stored key (case, spaces vs underscores vs hyphens, stray padding).
  defp flat_fetch(map, key) when is_map(map) and is_binary(key) do
    case exact_fetch(map, key) do
      {:ok, _} = hit -> hit
      :error -> normalized_fetch(map, key)
    end
  end

  # Exact fetch: interned-atom form first, then the raw string, so both
  # atom-keyed (in-memory) and string-keyed (JSONB) maps resolve. Never interns a
  # new atom (avoids atom-table exhaustion on attacker-controlled keys).
  defp exact_fetch(map, key) do
    case existing_atom(key) do
      {:ok, atom} ->
        case Map.fetch(map, atom) do
          {:ok, _} = hit -> hit
          :error -> Map.fetch(map, key)
        end

      :error ->
        Map.fetch(map, key)
    end
  end

  # Format-insensitive fallback: canonicalize the reference and every candidate
  # key (downcase, collapse runs of space/underscore/hyphen to a single space,
  # trim) and return the first key that matches. This lets a workflow reference
  # `company context content` resolve a trigger payload keyed `Company Context
  # Content`, `company_context_content`, or with trailing spaces — the exact
  # class of mismatch that comes from human-authored sheet headers — without any
  # action having to canonicalize keys first. Reserved internal keys (`__*`, e.g.
  # `__cascade__`) never fuzzy-match, so cascade internals are never exposed.
  defp normalized_fetch(map, key) do
    target = canonical(key)

    matches =
      for {k, v} <- map, canonical_map_key(k) == target, do: v

    case Enum.uniq(matches) do
      [] ->
        :error

      [value] ->
        {:ok, value}

      _ambiguous ->
        Logger.warning(
          "[workflow] ambiguous format-insensitive field lookup for #{inspect(key)} — " <>
            "multiple stored keys canonicalize identically to different values; " <>
            "refusing to guess (treating reference as unresolved)"
        )

        :error
    end
  end

  defp canonical_map_key(k) when is_binary(k) do
    if String.starts_with?(k, "__"), do: nil, else: canonical(k)
  end

  defp canonical_map_key(k) when is_atom(k), do: canonical_map_key(Atom.to_string(k))
  defp canonical_map_key(_), do: nil

  defp canonical(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[\s_-]+/u, " ")
    |> String.trim()
  end

  defp existing_atom(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end
end
