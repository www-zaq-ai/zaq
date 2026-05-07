defmodule Zaq.Channels.CommunicationBridgeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{ChannelConfig, CommunicationBridge}
  alias Zaq.Repo

  defmodule StubBridge do
    def send_reply(_outgoing, _details), do: :ok

    def sync_provider_runtime(config) do
      send(self(), {:sync_provider_runtime, config.provider, config.enabled})
      :ok
    end
  end

  setup do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: StubBridge},
      email: %{bridge: StubBridge}
    })

    on_exit(fn ->
      if original_channels do
        Application.put_env(:zaq, :channels, original_channels)
      else
        Application.delete_env(:zaq, :channels)
      end
    end)

    :ok
  end

  defp insert_config(provider, attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    base = %{
      name: "cfg-#{provider}-#{unique}",
      provider: to_string(provider),
      kind: "retrieval",
      url: "https://#{provider}.example.com",
      token: "tok-#{unique}",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  describe "provider normalization and bridge resolution" do
    test "maps provider atom and string to same bridge" do
      assert CommunicationBridge.bridge_for(:mattermost) == StubBridge
      assert CommunicationBridge.bridge_for("mattermost") == StubBridge
    end

    test "maps email transport providers to :email bridge" do
      assert CommunicationBridge.provider_to_bridge_key("email:smtp") == :email
      assert CommunicationBridge.provider_to_bridge_key("email:imap") == :email
      assert CommunicationBridge.bridge_for("email:smtp") == StubBridge
      assert CommunicationBridge.bridge_for("email:imap") == StubBridge
    end

    test "returns missing bridge errors for unknown provider" do
      assert CommunicationBridge.bridge_for("definitely_missing_provider") == nil

      assert {:error, {:no_bridge, "definitely_missing_provider"}} =
               CommunicationBridge.resolve_bridge("definitely_missing_provider")
    end
  end

  describe "runtime delegation" do
    test "sync_provider_runtime delegates to bridge callback" do
      insert_config(:mattermost)

      assert :ok = CommunicationBridge.sync_provider_runtime(:mattermost)
      assert_received {:sync_provider_runtime, "mattermost", true}
    end

    test "sync_provider_runtime returns channel_not_configured when config missing" do
      assert {:error, {:channel_not_configured, :mattermost}} =
               CommunicationBridge.sync_provider_runtime(:mattermost)
    end
  end
end
