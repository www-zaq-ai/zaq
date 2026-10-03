defmodule ZaqWeb.Live.BO.Communication.EmailConnectorSelection do
  @moduledoc "Selects a live email connector for the dedicated IMAP and SMTP settings pages."

  import Phoenix.Component, only: [assign: 3]

  alias Zaq.Channels.ChannelConfig

  def initialize(socket, provider) do
    configs = ChannelConfig.list_by_provider(provider)

    selected_id =
      case configs do
        [] -> :new
        [config] -> config.id
        _ -> nil
      end

    socket |> assign(:configs, configs) |> assign(:selected_config_id, selected_id)
  end

  def name(configs, selected_id, default) do
    case Enum.find(configs, &(&1.id == selected_id)) do
      nil -> default
      config -> config.name
    end
  end

  def selected_channel(socket, provider) do
    case socket.assigns.selected_config_id do
      :new -> %ChannelConfig{provider: provider, enabled: false, settings: %{}}
      id -> fetch_channel(id, provider)
    end
  end

  defp fetch_channel(id, provider) do
    case ChannelConfig.get(id) do
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
