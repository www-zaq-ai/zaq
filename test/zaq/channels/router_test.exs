defmodule Zaq.Channels.RouterTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.Router
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Repo

  defmodule StubBridge do
    def send_reply(%Outgoing{} = outgoing, connection_details) do
      send(self(), {:send_reply, outgoing, connection_details})
      :ok
    end

    def send_typing(config, channel_id, details) do
      send(self(), {:send_typing, config.provider, channel_id, details})
      :ok
    end

    def add_reaction(config, channel_id, message_id, emoji, details) do
      send(self(), {:add_reaction, config.provider, channel_id, message_id, emoji, details})
      :ok
    end

    def remove_reaction(config, channel_id, message_id, emoji, details) do
      send(self(), {:remove_reaction, config.provider, channel_id, message_id, emoji, details})
      :ok
    end

    def subscribe_thread_reply(config, channel_id, thread_id) do
      send(self(), {:subscribe_thread_reply, config.provider, channel_id, thread_id})
      :ok
    end

    def unsubscribe_thread_reply(config, channel_id, thread_id) do
      send(self(), {:unsubscribe_thread_reply, config.provider, channel_id, thread_id})
      :ok
    end

    def start_runtime(config) do
      send(self(), {:start_runtime, config.provider, config.id})
      :ok
    end

    def stop_runtime(config) do
      send(self(), {:stop_runtime, config.provider, config.id})
      :ok
    end
  end

  defmodule FailingBridge do
    def send_reply(_outgoing, _connection_details), do: {:error, :delivery_failed}
  end

  setup do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: StubBridge},
      failing_platform: %{bridge: FailingBridge},
      web: %{bridge: Zaq.Channels.WebBridge}
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

  defp insert_config(provider) do
    unique = System.unique_integer([:positive])

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "cfg-#{provider}-#{unique}",
      provider: to_string(provider),
      kind: "retrieval",
      url: "https://#{provider}.example.com",
      token: "tok-#{unique}",
      enabled: true
    })
    |> Repo.insert!()
  end

  describe "deliver/1" do
    test "routes to correct bridge and returns :ok on success" do
      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        provider: :mattermost
      }

      assert :ok = Router.deliver(outgoing)
      assert_received {:send_reply, ^outgoing, _connection_details}
    end

    test "returns {:error, {:no_bridge, provider}} for unknown provider" do
      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        provider: :unknown_provider
      }

      assert {:error, {:no_bridge, :unknown_provider}} = Router.deliver(outgoing)
    end

    test "returns error from bridge on delivery failure" do
      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        provider: :failing_platform
      }

      assert {:error, :delivery_failed} = Router.deliver(outgoing)
    end

    test "passes empty connection_details for :web provider" do
      outgoing = %Outgoing{
        body: "hello",
        channel_id: "session-xyz",
        provider: :web,
        metadata: %{session_id: "session-xyz", request_id: "req-1"}
      }

      # WebBridge.send_reply broadcasts to PubSub — just verify no crash and no DB lookup
      Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:session-xyz")
      Router.deliver(outgoing)
      assert_received {:pipeline_result, "req-1", %Outgoing{}, nil}
    end
  end

  describe "outbound event routing" do
    setup do
      insert_config(:mattermost)
      :ok
    end

    test "send_typing/2 delegates to bridge" do
      assert :ok = Router.send_typing(:mattermost, "chan-1")
      assert_received {:send_typing, "mattermost", "chan-1", details}
      assert is_binary(details.url)
      assert is_binary(details.token)
    end

    test "add_reaction/4 delegates to bridge" do
      assert :ok = Router.add_reaction(:mattermost, "chan-1", "msg-1", "+1")
      assert_received {:add_reaction, "mattermost", "chan-1", "msg-1", "+1", _details}
    end

    test "remove_reaction/5 merges extra opts with connection details" do
      assert :ok =
               Router.remove_reaction(:mattermost, "chan-1", "msg-1", "+1", %{user_id: "u-1"})

      assert_received {:remove_reaction, "mattermost", "chan-1", "msg-1", "+1", details}
      assert details.user_id == "u-1"
      assert is_binary(details.url)
      assert is_binary(details.token)
    end

    test "subscribe/unsubscribe thread reply delegates to bridge" do
      assert :ok = Router.subscribe_thread_reply(:mattermost, "chan-1", "thread-1")
      assert_received {:subscribe_thread_reply, "mattermost", "chan-1", "thread-1"}

      assert :ok = Router.unsubscribe_thread_reply(:mattermost, "chan-1", "thread-1")
      assert_received {:unsubscribe_thread_reply, "mattermost", "chan-1", "thread-1"}
    end

    test "returns configuration error when provider has no enabled config" do
      assert {:error, {:channel_not_configured, :failing_platform}} =
               Router.send_typing(:failing_platform, "chan-1")
    end
  end

  describe "sync_config_runtime/2" do
    setup do
      config = insert_config(:mattermost)
      {:ok, config: config}
    end

    test "starts runtime when new config is enabled", %{config: config} do
      config_id = config.id
      assert :ok = Router.sync_config_runtime(nil, config)
      assert_received {:start_runtime, "mattermost", ^config_id}
    end

    test "stops runtime when enabled config is disabled", %{config: config} do
      config_id = config.id
      disabled = %{config | enabled: false}
      assert :ok = Router.sync_config_runtime(config, disabled)
      assert_received {:stop_runtime, "mattermost", ^config_id}
    end

    test "starts runtime when disabled config becomes enabled", %{config: config} do
      config_id = config.id
      disabled = %{config | enabled: false}
      assert :ok = Router.sync_config_runtime(disabled, config)
      assert_received {:start_runtime, "mattermost", ^config_id}
    end

    test "no-op when enabled state does not change", %{config: config} do
      assert :ok = Router.sync_config_runtime(config, config)
      refute_received {:start_runtime, _, _}
      refute_received {:stop_runtime, _, _}
    end
  end
end
