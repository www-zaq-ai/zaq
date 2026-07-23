defmodule Zaq.Utils.Map do
  @moduledoc "Map access helpers for mixed atom/string keys."

  @spec read_any(map(), [atom() | String.t()]) :: term() | nil
  def read_any(map, keys) when is_map(map) and is_list(keys) do
    case Enum.find(keys, &Map.has_key?(map, &1)) do
      nil -> nil
      key -> Map.get(map, key)
    end
  end

  def read_any(_map, _keys), do: nil

  @spec read_stringish(map(), [atom() | String.t()]) :: String.t() | nil
  def read_stringish(map, keys) do
    map
    |> read_any(keys)
    |> stringish_value()
  end

  @spec read_present(map(), [atom() | String.t()]) :: term() | nil
  def read_present(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} when not is_nil(value) and value != false -> value
        _ -> nil
      end
    end)
  end

  def read_present(_map, _keys), do: nil

  @spec read_present_stringish(map(), [atom() | String.t()]) :: String.t() | nil
  def read_present_stringish(map, keys) do
    map
    |> read_present(keys)
    |> stringish_value()
  end

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

  defp stringish_value(nil), do: nil
  defp stringish_value(value) when is_binary(value), do: value
  defp stringish_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringish_value(value) when is_integer(value), do: Integer.to_string(value)
  defp stringish_value(_value), do: nil
end
