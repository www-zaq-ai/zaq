defmodule ZaqWeb.Live.BO.Communication.EmailConnectorSelection do
  @moduledoc "Pure presentation helper over an Engine-owned email connector snapshot."

  import Phoenix.Component, only: [assign: 3]

  alias Zaq.Engine.ChannelConfig

  def initialize(socket, snapshot) do
    socket
    |> assign(:configs, snapshot.configs)
    |> assign(:selected_config_id, snapshot.selected_config_id)
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
      id -> Enum.find(socket.assigns.configs, &(&1.id == id and &1.provider == provider))
    end
  end

  def refresh(socket, snapshot), do: initialize(socket, snapshot)
end
