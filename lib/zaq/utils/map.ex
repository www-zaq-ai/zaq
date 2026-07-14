defmodule Zaq.Utils.Map do
  @moduledoc "Map access helpers for mixed atom/string keys."

  @spec read_any(map(), [atom() | String.t()]) :: term() | nil
  def read_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  def read_any(_map, _keys), do: nil

  @spec metadata_value(map(), atom() | String.t()) :: term() | nil
  def metadata_value(metadata, key) when is_map(metadata) and is_binary(key) do
    read_any(metadata, [key, existing_atom_key(key)])
  end

  def metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    read_any(metadata, [key, Atom.to_string(key)])
  end

  def metadata_value(_metadata, _key), do: nil

  @spec stringify_keys(map()) :: map()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  def stringify_keys(_map), do: %{}

  @spec metadata_subject(term()) :: String.t() | nil
  def metadata_subject(metadata) when is_map(metadata) do
    case read_any(metadata, ["subject", :subject]) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  def metadata_subject(_), do: nil

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
