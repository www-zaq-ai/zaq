defmodule Zaq.Agent.Tools.KnowledgeSources do
  @moduledoc "Source identities declared by knowledge tools for the chunks they return."

  @doc "Preserves first occurrence order, including sources exposed on denied chunks."
  @spec from_chunks([map()]) :: [String.t()]
  def from_chunks(chunks) do
    chunks
    |> Enum.map(&Map.get(&1, "source"))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end
end
