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
    {:ok, profile} = Adapter.connection_identity(%{channel_config_id: id, credential_id: 1})
    profile
  end

  def private_sink(config) do
    %{storage: {_module, opts}} = JidoChatBridge.resolve_connection_details(config, %{})
    Keyword.fetch!(opts, :sink_mfa)
  end

  def authentication_sink do
    Code.ensure_loaded!(Zaq.WhatsAppFixtures.AuthenticationCapture)

    {:ok, opts} =
      JidoChatBridge.authenticate(:whatsapp, %{op: :begin, owner: self()}, :fixture_owner, %{},
        config: Zaq.WhatsAppFixtures.AuthenticationCapture
      )

    Keyword.fetch!(opts, :sink_mfa)
  end

  defmodule AuthenticationCapture do
    @moduledoc false
    use Jido.Chat.Adapter
    def channel_type, do: :whatsapp
    def transform_incoming(_), do: {:error, :unused}
    def send_message(_, _, _), do: {:error, :unused}
    def authenticate(_, _, opts), do: {:ok, opts}
    def get(:zaq, :channels, _, _), do: %{whatsapp: %{adapter: __MODULE__}}
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
