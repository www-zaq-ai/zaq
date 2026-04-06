defmodule Zaq.E2E.LogCollector do
  @moduledoc false

  use Agent

  @max_entries 500

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc "Adds a log entry to the ring buffer (capped at #{@max_entries} entries)."
  def push(%{level: _level, message: _message, timestamp: _timestamp} = entry) do
    Agent.update(__MODULE__, fn entries ->
      new_entries = [entry | entries]

      if length(new_entries) > @max_entries do
        Enum.take(new_entries, @max_entries)
      else
        new_entries
      end
    end)
  end

  @doc "Returns recent entries. Accepts `:limit` (default 100) and `:level` filter (atom or string)."
  def recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    level = Keyword.get(opts, :level, nil)

    Agent.get(__MODULE__, fn entries ->
      entries
      |> maybe_filter_level(level)
      |> Enum.take(limit)
    end)
  end

  @doc "Clears all entries."
  def clear do
    Agent.update(__MODULE__, fn _ -> [] end)
  end

  defp maybe_filter_level(entries, nil), do: entries

  defp maybe_filter_level(entries, level) when is_atom(level) do
    Enum.filter(entries, &(&1.level == level))
  end

  defp maybe_filter_level(entries, level) when is_binary(level) do
    atom_level = String.to_existing_atom(level)
    Enum.filter(entries, &(&1.level == atom_level))
  rescue
    _ -> entries
  end
end
