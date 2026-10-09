defmodule Zaq.ConnectorConfig.ImapSettings do
  @moduledoc "Pure IMAP settings access; no persistence, credentials or listener lifecycle."

  @spec get(map() | nil, atom() | String.t(), term()) :: term()
  def get(config, key, default \\ nil)

  def get(config, key, default) when is_map(config) and (is_atom(key) or is_binary(key)) do
    keys = lookup_keys(config, key)

    case fetch_first(config, keys) do
      {:ok, value} ->
        value

      :error ->
        with imap when is_map(imap) <- imap_settings(config),
             {:ok, value} <- fetch_first(imap, keys) do
          value
        else
          _ -> default
        end
    end
  end

  def get(_config, _key, default), do: default

  defp lookup_keys(_map, key) when is_atom(key), do: [key, Atom.to_string(key)]
  defp lookup_keys(map, key) when is_binary(key), do: [key, atom_key_for_string(map, key)]

  defp fetch_first(map, keys) do
    Enum.reduce_while(keys, :error, fn
      nil, _acc ->
        {:cont, :error}

      key, _acc ->
        case Map.fetch(map, key) do
          {:ok, _} = hit -> {:halt, hit}
          :error -> {:cont, :error}
        end
    end)
  end

  defp atom_key_for_string(map, key) do
    Enum.find_value(map, fn
      {candidate, _} when is_atom(candidate) ->
        if Atom.to_string(candidate) == key, do: candidate

      _ ->
        nil
    end)
  end

  defp imap_settings(config) do
    case Map.get(config, :settings) || Map.get(config, "settings") do
      settings when is_map(settings) ->
        case Map.get(settings, :imap) || Map.get(settings, "imap") do
          imap when is_map(imap) -> imap
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
