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
  """

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

  # Fetch a string key trying the interned-atom form first, then the raw string,
  # so both atom-keyed (in-memory) and string-keyed (JSONB) maps resolve. Never
  # interns a new atom (avoids atom-table exhaustion on attacker-controlled keys).
  defp flat_fetch(map, key) when is_map(map) and is_binary(key) do
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

  defp flat_fetch(_map, _key), do: :error

  defp existing_atom(key) do
    {:ok, String.to_existing_atom(key)}
  rescue
    ArgumentError -> :error
  end
end
