defmodule Zaq.Utils.Map do
  @moduledoc "Map access helpers for mixed atom/string keys."

  @spec read_any(map(), [atom() | String.t()]) :: term() | nil
  def read_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  def read_any(_map, _keys), do: nil

  @spec metadata_subject(term()) :: String.t() | nil
  def metadata_subject(metadata) when is_map(metadata) do
    case read_any(metadata, ["subject", :subject]) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  def metadata_subject(_), do: nil
end
