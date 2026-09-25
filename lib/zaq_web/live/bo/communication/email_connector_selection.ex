defmodule ZaqWeb.Live.BO.Communication.EmailConnectorSelection do
  @moduledoc "Selects a live email connector for the dedicated IMAP and SMTP settings pages."

  import Phoenix.Component, only: [assign: 3]

  alias Zaq.Channels.ChannelConfig

  def initialize(socket, provider) do
    configs = ChannelConfig.list_by_provider(provider)

    selected_id =
      case configs do
        [config] -> config.id
        _ -> nil
      end

    socket |> assign(:configs, configs) |> assign(:selected_config_id, selected_id)
  end

  def selected_channel(socket, provider) do
    case ChannelConfig.get(socket.assigns.selected_config_id) do
      %ChannelConfig{provider: ^provider, archived_at: nil} = channel -> channel
      _ -> nil
    end
  end

  def refresh(socket, provider) do
    configs = ChannelConfig.list_by_provider(provider)

    selected_id =
      case {socket.assigns.selected_config_id, configs} do
        {nil, [config]} -> config.id
        {id, _} -> id
      end

    socket |> assign(:configs, configs) |> assign(:selected_config_id, selected_id)
  end
end
