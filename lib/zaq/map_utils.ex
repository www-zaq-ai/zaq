defmodule Zaq.MapUtils do
  @moduledoc """
  Utility functions for maps that may carry atom or string keys.

  Common when deserialising JSONB data where keys may appear in either form
  depending on whether the map was atomised by a caller or loaded raw from the DB.
  """

  @doc """
  Returns the value for `atom_key` if present, falling back to `string_key`.

  Useful when a map may have been atomised (`DagBuilder.atomize_keys/1`) or
  arrive as raw string-key JSONB from the database.
  """
  @spec fetch_either(map(), atom(), String.t()) :: term()
  def fetch_either(map, atom_key, string_key) when is_map(map) do
    Map.get(map, atom_key) || Map.get(map, string_key)
  end
end
