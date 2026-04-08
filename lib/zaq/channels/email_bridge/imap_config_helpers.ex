defmodule Zaq.Channels.EmailBridge.ImapConfigHelpers do
  @moduledoc false

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

  @spec normalize_mailbox_names(list()) :: [String.t()]
  def normalize_mailbox_names(raw_mailboxes) when is_list(raw_mailboxes) do
    raw_mailboxes
    |> Enum.map(&mailbox_name/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec selected_mailboxes_for_listener(map()) :: [String.t()]
  def selected_mailboxes_for_listener(config) when is_map(config) do
    config
    |> get(:selected_mailboxes)
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @spec normalize_bridge_config(map()) :: map()
  def normalize_bridge_config(config) when is_map(config) do
    %{
      provider: get(config, :provider) || "email:imap",
      url: get(config, :url),
      token: first_non_nil([get(config, :token), get(config, :password)]),
      username: get(config, :username),
      port: get(config, :port),
      ssl: get(config, :ssl),
      ssl_depth: get(config, :ssl_depth),
      timeout: get(config, :timeout),
      idle_timeout: get(config, :idle_timeout),
      poll_interval: get(config, :poll_interval),
      mark_as_read: get(config, :mark_as_read),
      load_initial_unread: get(config, :load_initial_unread),
      selected_mailboxes:
        config
        |> get(:selected_mailboxes)
        |> List.wrap()
        |> normalize_mailbox_names()
    }
  end

  defp lookup_keys(_map, key) when is_atom(key), do: [key, Atom.to_string(key)]

  defp lookup_keys(map, key) when is_binary(key) do
    [key, atom_key_for_string(map, key)]
  end

  defp fetch_first(map, keys) do
    Enum.reduce_while(keys, :error, fn
      nil, _acc ->
        {:cont, :error}

      lookup_key, _acc ->
        case Map.fetch(map, lookup_key) do
          {:ok, _value} = hit -> {:halt, hit}
          :error -> {:cont, :error}
        end
    end)
  end

  defp atom_key_for_string(map, key) do
    Enum.find_value(map, fn
      {lookup_key, _value} when is_atom(lookup_key) ->
        if Atom.to_string(lookup_key) == key, do: lookup_key

      _ ->
        nil
    end)
  end

  defp imap_settings(config) do
    settings = Map.get(config, :settings) || Map.get(config, "settings")

    case settings do
      settings when is_map(settings) ->
        case Map.get(settings, :imap) || Map.get(settings, "imap") do
          imap when is_map(imap) -> imap
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp mailbox_name({mailbox, _delimiter, _flags}) when is_binary(mailbox), do: mailbox
  defp mailbox_name(%{mailbox: mailbox}) when is_binary(mailbox), do: mailbox
  defp mailbox_name(%{"mailbox" => mailbox}) when is_binary(mailbox), do: mailbox
  defp mailbox_name(mailbox) when is_binary(mailbox), do: mailbox
  defp mailbox_name(_), do: nil

  defp first_non_nil(values) when is_list(values) do
    Enum.find(values, fn value -> not is_nil(value) end)
  end
end
