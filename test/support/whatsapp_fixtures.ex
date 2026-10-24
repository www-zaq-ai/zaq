defmodule Zaq.WhatsAppFixtures do
  @moduledoc "WhatsApp connectors and serial-test channel configuration."

  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo
  alias Zaq.TestSupport.ApplicationEnv

  def connector(attrs \\ %{}) do
    defaults = %{name: Ecto.UUID.generate(), provider: "whatsapp", kind: "retrieval"}

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(defaults, attrs), adapter_authentication: true)
    |> Repo.insert!()
  end

  def runtime_config(id),
    do: %{
      id: id,
      provider: "whatsapp",
      settings: %{"credential_document_id" => 1},
      url: "",
      token: ""
    }

  def bound_profile(id) do
    Adapter.connection_options(%{channel_config_id: id, credential_id: 1},
      context: :runtime,
      sink_mfa: JidoChatBridge.storage_sink(%{provider: "whatsapp"})
    ).profile
  end

  def state_spec(bridge_id, config),
    do: %{
      id: :state,
      start: {State, :start_link, [[bridge_id: bridge_id, config: config, provider: :whatsapp]]}
    }

  # Only call from async: false tests; restore absence as well as existing values.
  def configure_channels(adapter) do
    ApplicationEnv.put(:zaq, :channels, %{
      whatsapp: %{bridge: JidoChatBridge, adapter: adapter, ingress_mode: :linked_device}
    })
  end
end
