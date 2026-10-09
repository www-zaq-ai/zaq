defmodule Zaq.Channels.EmailBridge.ImapConfigHelpers do
  @moduledoc "Provider-local mailbox and listener configuration normalization."

  alias Zaq.ConnectorConfig.ImapSettings

  @spec get(map() | nil, atom() | String.t(), term()) :: term()
  def get(config, key, default \\ nil)

  def get(config, key, default), do: ImapSettings.get(config, key, default)

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
      id: get(config, :id),
      settings: normalize_settings(config),
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

  defp normalize_settings(config) do
    case Map.get(config, :settings) || Map.get(config, "settings") do
      settings when is_map(settings) -> settings
      _ -> %{}
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
