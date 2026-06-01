defmodule Zaq.Utils.Scopes do
  @moduledoc "Utilities for normalizing scope lists."

  @spec normalize(term()) :: [String.t()]
  def normalize(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize(_), do: []
end
