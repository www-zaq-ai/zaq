defmodule Zaq.Channels.Router do
  @moduledoc """
  Stateless outbound router for all ZAQ channels.

  `deliver/1` resolves the correct bridge module from app config (by provider),
  fetches connection details from the DB (by channel_id), and delegates to
  `bridge.send_reply/2`. The bridge is responsible for adapter-specific delivery.

  For `provider: :web`, connection details are empty — the web bridge delivers
  via PubSub only.
  """

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Messages.Outgoing

  @doc """
  Delivers `%Outgoing{}` to the correct bridge.

  Returns `:ok` on success or `{:error, reason}` on failure.
  Returns `{:error, {:no_bridge, provider}}` if no bridge is configured for the provider.
  """
  @spec deliver(Outgoing.t()) :: :ok | {:error, term()}
  def deliver(%Outgoing{} = outgoing) do
    case ChannelConfig.resolve_bridge(outgoing.provider) do
      nil ->
        {:error, {:no_bridge, outgoing.provider}}

      bridge ->
        connection_details = fetch_connection_details(outgoing.provider)
        bridge.send_reply(outgoing, connection_details)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fetch_connection_details(:web), do: %{}

  defp fetch_connection_details(provider) do
    case ChannelConfig.get_by_provider(to_string(provider)) do
      nil -> %{}
      config -> %{url: config.url, token: config.token}
    end
  end
end
