defmodule Zaq.Channels.CommunicationBridgeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.{Bridge, ChannelConfig, CommunicationBridge}
  alias Zaq.Repo

  defmodule StubBridge do
    def send_reply(_outgoing, _details), do: :ok

    def send_typing(_config, channel_id, details) do
      send(self(), {:send_typing, channel_id, details})
      :ok
    end

    def sync_provider_runtime(config) do
      send(self(), {:sync_provider_runtime, config.provider, config.enabled})
      :ok
    end

    def add_reaction(_config, channel_id, message_id, emoji, details) do
      send(self(), {:add_reaction, channel_id, message_id, emoji, details})
      :ok
    end

    def remove_reaction(_config, channel_id, message_id, emoji, details) do
      send(self(), {:remove_reaction, channel_id, message_id, emoji, details})
      :ok
    end

    def subscribe_thread_reply(_config, channel_id, thread_id) do
      send(self(), {:subscribe_thread_reply, channel_id, thread_id})
      :ok
    end

    def unsubscribe_thread_reply(_config, channel_id, thread_id) do
      send(self(), {:unsubscribe_thread_reply, channel_id, thread_id})
      :ok
    end

    def open_dm_channel(author_id, details) do
      send(self(), {:open_dm_channel, author_id, details})
      {:ok, "dm-chan-1"}
    end

    def fetch_profile(author_id, details) do
      send(self(), {:fetch_profile, author_id, details})
      {:ok, %{id: author_id, username: "alice"}}
    end

    def list_mailboxes(config, details) do
      send(self(), {:list_mailboxes, config, details})
      {:ok, ["INBOX", "Archive"]}
    end

    def test_connection(config, channel_id) do
      send(self(), {:test_connection, config, channel_id})
      {:ok, %{id: channel_id}}
    end

    def start_runtime(config) do
      send(self(), {:start_runtime, config.provider, config.enabled})
      :ok
    end

    def stop_runtime(config) do
      send(self(), {:stop_runtime, config.provider, config.enabled})
      :ok
    end

    def sync_runtime(before_config, after_config) do
      send(self(), {:sync_runtime, before_config, after_config})
      :ok
    end

    def handle_webhook(config, payload) do
      send(self(), {:handle_webhook, config, payload})
      {:ok, %{processed: true}}
    end
  end

  defmodule StubBridgeWithoutTyping do
    def send_reply(_outgoing, _details), do: :ok
  end

  defmodule StubBridgeWithoutRuntime do
    def send_reply(_outgoing, _details), do: :ok
  end

  defmodule StubBridgeFallbackRuntime do
    def send_reply(_outgoing, _details), do: :ok

    def start_runtime(config) do
      send(self(), {:fallback_start_runtime, config.provider, config.enabled})
      :ok
    end

    def stop_runtime(config) do
      send(self(), {:fallback_stop_runtime, config.provider, config.enabled})
      :ok
    end
  end

  defmodule StubBridgeWithoutTestConnection do
    def send_reply(_outgoing, _details), do: :ok
  end

  defmodule StubBridgeWithoutWebhook do
    def send_reply(_outgoing, _details), do: :ok
  end

  defmodule StubBridgeIngress do
    def send_reply(_outgoing, _details), do: :ok

    def ensure_ingress_subscription(config, params) do
      send(self(), {:ensure_ingress_subscription, config, params})
      {:ok, %{status: :ensured, params: params}}
    end

    def list_ingress_subscriptions(config, params) do
      send(self(), {:list_ingress_subscriptions, config, params})
      {:ok, [%{id: "sub-1"}]}
    end

    def delete_ingress_subscription(config, params) do
      send(self(), {:delete_ingress_subscription, config, params})

      {:ok, %{deleted: true, id: params["id"] || params[:id]}}
    end
  end

  defmodule StubBridgeWithoutIngress do
    def send_reply(_outgoing, _details), do: :ok
  end

  defmodule StubBridgeIngressError do
    def send_reply(_outgoing, _details), do: :ok

    def ensure_ingress_subscription(_config, _params), do: {:error, :provider_down}
  end

  defmodule StubNodeRouter do
    alias Zaq.Engine.Messages.Outgoing

    def dispatch(event) do
      send(self(), {:node_router_dispatch, event})

      response =
        case Keyword.get(event.opts[:pipeline_opts] || [], :node_router_response) do
          :nil_response -> nil
          nil -> %Outgoing{body: "ok", provider: :mattermost, channel_id: "c1"}
          configured -> configured
        end

      %{event | response: response}
    end
  end

  defmodule StubAgent do
    def get_conversation_enabled_agent(1), do: {:error, :agent_not_found}
    def get_conversation_enabled_agent(2), do: {:error, :inactive_agent}
    def get_conversation_enabled_agent(3), do: {:ok, %{id: 3}}
    def get_conversation_enabled_agent(_), do: {:error, :agent_not_found}
  end

  setup do
    original_channels = Application.get_env(:zaq, :channels)
    original_bridge_path = Path.expand("../../../lib/zaq/channels/bridge.ex", __DIR__)
    original_bridge_source = File.read!(original_bridge_path)

    bridge_base_source =
      String.replace(original_bridge_source, "Zaq.Channels.Bridge", "Zaq.Channels.BridgeBase")

    :code.purge(Zaq.Channels.Bridge)
    :code.delete(Zaq.Channels.Bridge)

    Code.compiler_options(ignore_module_conflict: true)

    Code.compile_string(bridge_base_source)

    Code.compile_string("""
    defmodule Zaq.Channels.Bridge do
      defdelegate route_incoming(bridge_module, config, payload, sink_opts),
        to: Zaq.Channels.BridgeBase

      defdelegate before_incoming(config, payload, sink_opts, bridge_module),
        to: Zaq.Channels.BridgeBase

      defdelegate after_incoming(config, payload, sink_opts, result, bridge_module),
        to: Zaq.Channels.BridgeBase

      defdelegate ack_from_event_response(response), to: Zaq.Channels.BridgeBase
      defdelegate bridge_for(provider), to: Zaq.Channels.BridgeBase
      defdelegate provider_to_bridge_key(provider), to: Zaq.Channels.BridgeBase
      defdelegate resolve_bridge(provider), to: Zaq.Channels.BridgeBase
      defdelegate fetch_connection_details(provider), to: Zaq.Channels.BridgeBase
      defdelegate fetch_any_channel_config(provider), to: Zaq.Channels.BridgeBase
      defdelegate dispatch_provider_runtime_sync(bridge, config), to: Zaq.Channels.BridgeBase
      defdelegate capability_snapshot(provider), to: Zaq.Channels.BridgeBase
      defdelegate sync_config_runtime(before_config, after_config), to: Zaq.Channels.BridgeBase
      defdelegate sync_provider_runtime(provider), to: Zaq.Channels.BridgeBase
      defdelegate required_capabilities(kind), to: Zaq.Channels.BridgeBase
      defdelegate capability_meta(kind), to: Zaq.Channels.BridgeBase

      def fetch_channel_config(provider) do
        case Process.get(:bridge_fetch_channel_config_override) do
          nil -> Zaq.Channels.BridgeBase.fetch_channel_config(provider)
          result -> result
        end
      end
    end
    """)

    Code.compiler_options(ignore_module_conflict: false)

    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: StubBridge},
      email: %{bridge: StubBridge}
    })

    on_exit(fn ->
      Process.delete(:bridge_fetch_channel_config_override)

      :code.purge(Zaq.Channels.Bridge)
      :code.delete(Zaq.Channels.Bridge)
      :code.purge(Zaq.Channels.BridgeBase)
      :code.delete(Zaq.Channels.BridgeBase)

      Code.compiler_options(ignore_module_conflict: true)
      Code.compile_file(original_bridge_path)
      Code.compiler_options(ignore_module_conflict: false)

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
      assert Bridge.bridge_for(:mattermost) == StubBridge
      assert Bridge.bridge_for("mattermost") == StubBridge
    end

    test "maps email transport providers to :email bridge" do
      assert Bridge.provider_to_bridge_key("email:smtp") == :email
      assert Bridge.provider_to_bridge_key("email:imap") == :email
      assert Bridge.bridge_for("email:smtp") == StubBridge
      assert Bridge.bridge_for("email:imap") == StubBridge
    end

    test "returns missing bridge errors for unknown provider" do
      assert Bridge.bridge_for("definitely_missing_provider") == nil

      assert {:error, {:no_bridge, "definitely_missing_provider"}} =
               Bridge.resolve_bridge("definitely_missing_provider")
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

    test "sync_provider_runtime returns no_bridge when config exists but provider has no bridge" do
      insert_config("slack")

      assert {:error, {:no_bridge, "slack"}} = CommunicationBridge.sync_provider_runtime("slack")
    end
  end

  describe "send_typing/2" do
    setup do
      insert_config(:mattermost)
      :ok
    end

    test "delegates typing to bridge when callback is supported" do
      assert :ok = CommunicationBridge.send_typing(:mattermost, "chan-1")

      assert_received {:send_typing, "chan-1", details}
      assert is_binary(details.url)
      assert String.starts_with?(details.url, "https://mattermost.example.com")
      assert is_binary(details.token)
    end

    test "returns no_bridge error when provider is unknown" do
      assert {:error, {:no_bridge, "missing-provider"}} =
               CommunicationBridge.send_typing("missing-provider", "chan-1")
    end

    test "returns channel_not_configured when provider config is missing" do
      assert {:error, {:channel_not_configured, :email}} =
               CommunicationBridge.send_typing(:email, "chan-1")
    end

    test "returns :ok when bridge does not implement send_typing callback" do
      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{mattermost: %{bridge: StubBridgeWithoutTyping}})

      on_exit(fn ->
        if original_channels do
          Application.put_env(:zaq, :channels, original_channels)
        else
          Application.delete_env(:zaq, :channels)
        end
      end)

      assert :ok = CommunicationBridge.send_typing(:mattermost, "chan-1")
    end
  end

  describe "reaction and thread reply delegates" do
    setup do
      insert_config(:mattermost)
      :ok
    end

    test "add_reaction delegates to bridge callback" do
      assert :ok = CommunicationBridge.add_reaction(:mattermost, "chan-1", "msg-1", "thumbsup")
      assert_received {:add_reaction, "chan-1", "msg-1", "thumbsup", details}
      assert is_map(details)
    end

    test "add_reaction accepts integer message_id" do
      assert :ok = CommunicationBridge.add_reaction(:mattermost, "chan-1", 52, "thumbsup")
      assert_received {:add_reaction, "chan-1", 52, "thumbsup", details}
      assert is_map(details)
    end

    test "remove_reaction merges extra opts into connection details" do
      assert :ok =
               CommunicationBridge.remove_reaction(:mattermost, "chan-1", "msg-1", "eyes", %{
                 request_id: "req-1"
               })

      assert_received {:remove_reaction, "chan-1", "msg-1", "eyes", details}
      assert details.request_id == "req-1"
      assert is_binary(details.url)
      assert is_binary(details.token)
    end

    test "remove_reaction accepts integer message_id" do
      assert :ok = CommunicationBridge.remove_reaction(:mattermost, "chan-1", 52, "eyes")
      assert_received {:remove_reaction, "chan-1", 52, "eyes", details}
      assert is_binary(details.url)
      assert is_binary(details.token)
    end

    test "subscribe_thread_reply delegates to bridge callback" do
      assert :ok = CommunicationBridge.subscribe_thread_reply(:mattermost, "chan-1", "thread-1")
      assert_received {:subscribe_thread_reply, "chan-1", "thread-1"}
    end

    test "unsubscribe_thread_reply delegates to bridge callback" do
      assert :ok = CommunicationBridge.unsubscribe_thread_reply(:mattermost, "chan-1", "thread-1")
      assert_received {:unsubscribe_thread_reply, "chan-1", "thread-1"}
    end

    test "reaction/thread functions return no_bridge for unknown providers" do
      assert {:error, {:no_bridge, "missing-provider"}} =
               CommunicationBridge.add_reaction("missing-provider", "chan-1", "msg-1", "ok")

      assert {:error, {:no_bridge, "missing-provider"}} =
               CommunicationBridge.remove_reaction("missing-provider", "chan-1", "msg-1", "ok")

      assert {:error, {:no_bridge, "missing-provider"}} =
               CommunicationBridge.subscribe_thread_reply(
                 "missing-provider",
                 "chan-1",
                 "thread-1"
               )

      assert {:error, {:no_bridge, "missing-provider"}} =
               CommunicationBridge.unsubscribe_thread_reply(
                 "missing-provider",
                 "chan-1",
                 "thread-1"
               )
    end

    test "reaction/thread functions return channel_not_configured for known provider without config" do
      assert {:error, {:channel_not_configured, :email}} =
               CommunicationBridge.add_reaction(:email, "chan-1", "msg-1", "ok")

      assert {:error, {:channel_not_configured, :email}} =
               CommunicationBridge.remove_reaction(:email, "chan-1", "msg-1", "ok")

      assert {:error, {:channel_not_configured, :email}} =
               CommunicationBridge.subscribe_thread_reply(:email, "chan-1", "thread-1")

      assert {:error, {:channel_not_configured, :email}} =
               CommunicationBridge.unsubscribe_thread_reply(:email, "chan-1", "thread-1")
    end
  end

  describe "sync_config_runtime/2" do
    setup do
      insert_config(:mattermost)
      :ok
    end

    test "uses bridge sync_runtime when callback is implemented" do
      before_config = %{enabled: true}
      after_config = %{provider: "mattermost", enabled: false}

      assert :ok = CommunicationBridge.sync_config_runtime(before_config, after_config)
      assert_received {:sync_runtime, ^before_config, ^after_config}
    end

    test "falls back to start_runtime for nil->enabled true" do
      original_channels = Application.get_env(:zaq, :channels)
      Application.put_env(:zaq, :channels, %{mattermost: %{bridge: StubBridgeWithoutRuntime}})

      on_exit(fn ->
        if original_channels, do: Application.put_env(:zaq, :channels, original_channels)
      end)

      assert :ok =
               CommunicationBridge.sync_config_runtime(nil, %{
                 provider: "mattermost",
                 enabled: true
               })

      refute_received {:sync_runtime, _, _}
    end

    test "fallback returns :ok for nil->enabled false and unchanged configs" do
      original_channels = Application.get_env(:zaq, :channels)
      Application.put_env(:zaq, :channels, %{mattermost: %{bridge: StubBridgeWithoutRuntime}})

      on_exit(fn ->
        if original_channels, do: Application.put_env(:zaq, :channels, original_channels)
      end)

      assert :ok =
               CommunicationBridge.sync_config_runtime(nil, %{
                 provider: "mattermost",
                 enabled: false
               })

      assert :ok =
               CommunicationBridge.sync_config_runtime(
                 %{enabled: true},
                 %{provider: "mattermost", enabled: true}
               )
    end

    test "fallback start/stop runtime paths call bridge callbacks" do
      original_channels = Application.get_env(:zaq, :channels)
      Application.put_env(:zaq, :channels, %{mattermost: %{bridge: StubBridgeFallbackRuntime}})

      on_exit(fn ->
        if original_channels, do: Application.put_env(:zaq, :channels, original_channels)
      end)

      assert :ok =
               CommunicationBridge.sync_config_runtime(%{enabled: true}, %{
                 provider: "mattermost",
                 enabled: false
               })

      assert :ok =
               CommunicationBridge.sync_config_runtime(%{enabled: false}, %{
                 provider: "mattermost",
                 enabled: true
               })

      assert_received {:fallback_stop_runtime, "mattermost", false}
      assert_received {:fallback_start_runtime, "mattermost", true}
    end

    test "returns no_bridge error when provider is unknown" do
      assert {:error, {:no_bridge, "missing-provider"}} =
               CommunicationBridge.sync_config_runtime(nil, %{
                 provider: "missing-provider",
                 enabled: true
               })
    end
  end

  describe "test_connection/2" do
    test "delegates test_connection when callback exists" do
      config = %{provider: "mattermost", id: 1}
      assert {:ok, %{id: "chan-1"}} = CommunicationBridge.test_connection(config, "chan-1")
      assert_received {:test_connection, ^config, "chan-1"}
    end

    test "returns unsupported when bridge lacks callback" do
      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: StubBridgeWithoutTestConnection}
      })

      on_exit(fn ->
        if original_channels, do: Application.put_env(:zaq, :channels, original_channels)
      end)

      assert {:error, :unsupported} =
               CommunicationBridge.test_connection(%{provider: "mattermost"}, "chan-1")
    end

    test "returns no_bridge for unknown provider" do
      assert {:error, {:no_bridge, "missing-provider"}} =
               CommunicationBridge.test_connection(%{provider: "missing-provider"}, "chan-1")
    end
  end

  describe "handle_webhook/2" do
    setup do
      insert_config(:mattermost)
      :ok
    end

    test "delegates to bridge when callback is supported" do
      payload = %{event: "message", text: "hello"}
      assert {:ok, %{processed: true}} = CommunicationBridge.handle_webhook(:mattermost, payload)
      assert_received {:handle_webhook, config, ^payload}
      assert is_map(config)
    end

    test "returns no_bridge error when provider is unknown" do
      assert {:error, {:no_bridge, "missing-provider"}} =
               CommunicationBridge.handle_webhook("missing-provider", %{text: "hi"})
    end

    test "returns dropped when provider config is missing" do
      assert {:ok, %{dropped: true, drop_reason: :channel_disabled, provider: "email"}} =
               CommunicationBridge.handle_webhook(:email, %{text: "hi"})
    end

    test "returns unsupported when bridge lacks handle_webhook callback" do
      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: StubBridgeWithoutWebhook}
      })

      on_exit(fn ->
        if original_channels do
          Application.put_env(:zaq, :channels, original_channels)
        else
          Application.delete_env(:zaq, :channels)
        end
      end)

      assert {:error, :unsupported} =
               CommunicationBridge.handle_webhook(:mattermost, %{text: "hi"})
    end

    test "returns upstream config error for non-channel_not_configured reasons" do
      Process.put(:bridge_fetch_channel_config_override, {:error, :db_unavailable})

      assert {:error, :db_unavailable} =
               CommunicationBridge.handle_webhook(:mattermost, %{text: "hi"})
    end
  end

  describe "ingress subscription delegates" do
    setup do
      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{
        mattermost: %{bridge: StubBridgeIngress},
        email: %{bridge: StubBridgeWithoutIngress}
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

    test "ensure_ingress_subscription delegates when callback exists" do
      insert_config(:mattermost)

      params = %{"topic" => "sales"}

      assert {:ok, %{status: :ensured}} =
               CommunicationBridge.ensure_ingress_subscription(:mattermost, params)

      assert_received {:ensure_ingress_subscription, config, ^params}
      assert config.enabled == true
    end

    test "ensure_ingress_subscription returns :unsupported when callback missing" do
      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{mattermost: %{bridge: StubBridgeWithoutIngress}})

      on_exit(fn ->
        if original_channels do
          Application.put_env(:zaq, :channels, original_channels)
        else
          Application.delete_env(:zaq, :channels)
        end
      end)

      insert_config(:mattermost)

      assert {:error, :unsupported} =
               CommunicationBridge.ensure_ingress_subscription(:mattermost, %{})
    end

    test "list_ingress_subscriptions uses fetch_any_channel_config and delegates" do
      insert_config(:mattermost, %{enabled: false})

      params = %{"topic" => "sales"}

      assert {:ok, [%{id: "sub-1"}]} =
               CommunicationBridge.list_ingress_subscriptions(:mattermost, params)

      assert_received {:list_ingress_subscriptions, config, ^params}
      assert config.enabled == false
    end

    test "list_ingress_subscriptions returns :unsupported when callback missing" do
      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{mattermost: %{bridge: StubBridgeWithoutIngress}})

      on_exit(fn ->
        if original_channels do
          Application.put_env(:zaq, :channels, original_channels)
        else
          Application.delete_env(:zaq, :channels)
        end
      end)

      insert_config(:mattermost, %{enabled: false})

      assert {:error, :unsupported} =
               CommunicationBridge.list_ingress_subscriptions(:mattermost, %{})
    end

    test "delete_ingress_subscription uses fetch_any_channel_config and delegates" do
      insert_config(:mattermost, %{enabled: false})

      params = %{"id" => "sub-1"}

      assert {:ok, %{deleted: true, id: "sub-1"}} =
               CommunicationBridge.delete_ingress_subscription(:mattermost, params)

      assert_received {:delete_ingress_subscription, config, ^params}
      assert config.enabled == false
    end

    test "delete_ingress_subscription returns :unsupported when callback missing" do
      original_channels = Application.get_env(:zaq, :channels)

      Application.put_env(:zaq, :channels, %{mattermost: %{bridge: StubBridgeWithoutIngress}})

      on_exit(fn ->
        if original_channels do
          Application.put_env(:zaq, :channels, original_channels)
        else
          Application.delete_env(:zaq, :channels)
        end
      end)

      insert_config(:mattermost, %{enabled: false})

      assert {:error, :unsupported} =
               CommunicationBridge.delete_ingress_subscription(:mattermost, %{})
    end

    test "ingress functions return no_bridge for unknown provider" do
      assert {:error, {:no_bridge, "missing-provider"}} =
               CommunicationBridge.ensure_ingress_subscription("missing-provider", %{})

      assert {:error, {:no_bridge, "missing-provider"}} =
               CommunicationBridge.list_ingress_subscriptions("missing-provider", %{})

      assert {:error, {:no_bridge, "missing-provider"}} =
               CommunicationBridge.delete_ingress_subscription("missing-provider", %{})
    end

    test "ensure_ingress_subscription returns channel_not_configured when enabled config missing" do
      assert {:error, {:channel_not_configured, :email}} =
               CommunicationBridge.ensure_ingress_subscription(:email, %{})
    end

    test "list/delete ingress return channel_not_configured when no config exists" do
      assert {:error, {:channel_not_configured, :email}} =
               CommunicationBridge.list_ingress_subscriptions(:email, %{})

      assert {:error, {:channel_not_configured, :email}} =
               CommunicationBridge.delete_ingress_subscription(:email, %{})
    end
  end

  describe "run_pipeline_with_node_router/5" do
    test "normalizes all supported response shapes" do
      msg = %Zaq.Engine.Messages.Incoming{content: "hi", provider: :mattermost, channel_id: "c1"}
      actor = %{id: "u1", provider: :mattermost}

      outgoing = %Zaq.Engine.Messages.Outgoing{
        body: "ok",
        provider: :mattermost,
        channel_id: "c1"
      }

      assert %Zaq.Engine.Messages.Outgoing{} =
               CommunicationBridge.run_pipeline_with_node_router(
                 msg,
                 [node_router_response: outgoing],
                 %{"agent_id" => "2"},
                 actor,
                 StubNodeRouter
               )

      assert %Zaq.Engine.Messages.Outgoing{} =
               CommunicationBridge.run_pipeline_with_node_router(
                 msg,
                 [node_router_response: {:ok, outgoing}],
                 %{"agent_id" => "2"},
                 actor,
                 StubNodeRouter
               )

      assert {:error, :boom} =
               CommunicationBridge.run_pipeline_with_node_router(
                 msg,
                 [node_router_response: {:error, :boom}],
                 %{"agent_id" => "2"},
                 actor,
                 StubNodeRouter
               )

      assert :ok =
               CommunicationBridge.run_pipeline_with_node_router(
                 msg,
                 [node_router_response: :ok],
                 %{"agent_id" => "2"},
                 actor,
                 StubNodeRouter
               )

      assert :ok =
               CommunicationBridge.run_pipeline_with_node_router(
                 msg,
                 [node_router_response: :nil_response],
                 %{"agent_id" => "2"},
                 actor,
                 StubNodeRouter
               )

      assert {:error, {:invalid_pipeline_response, :unexpected}} =
               CommunicationBridge.run_pipeline_with_node_router(
                 msg,
                 [node_router_response: :unexpected],
                 %{"agent_id" => "2"},
                 actor,
                 StubNodeRouter
               )
    end

    test "adds agent_selection assign only for %{'agent_id' => _} shape" do
      msg = %Zaq.Engine.Messages.Incoming{content: "hi", provider: :mattermost, channel_id: "c1"}
      actor = %{id: "u1", provider: :mattermost}

      _ =
        CommunicationBridge.run_pipeline_with_node_router(
          msg,
          [node_router_response: :ok],
          %{"agent_id" => "3", "source" => "manual"},
          actor,
          StubNodeRouter
        )

      assert_received {:node_router_dispatch, event_with_assign}
      assert get_in(event_with_assign.assigns, ["agent_selection", "agent_id"]) == "3"

      _ =
        CommunicationBridge.run_pipeline_with_node_router(
          msg,
          [node_router_response: :ok],
          %{agent_id: "4"},
          actor,
          StubNodeRouter
        )

      assert_received {:node_router_dispatch, event_without_assign}
      assert event_without_assign.assigns == %{}
    end
  end

  describe "first_active_selection/2" do
    test "returns first conversation-enabled candidate" do
      candidates = [{:channel_assignment, "1"}, {:provider_default, "3"}, {:global_default, "2"}]

      assert %{"agent_id" => 3, "source" => "provider_default"} =
               CommunicationBridge.first_active_selection(candidates, StubAgent)
    end

    test "returns nil when no candidate resolves to conversation-enabled agent" do
      candidates = [
        {:channel_assignment, "abc"},
        {:provider_default, "1"},
        {:global_default, "2"}
      ]

      assert is_nil(CommunicationBridge.first_active_selection(candidates, StubAgent))
    end

    test "uses default Zaq.Agent module when not provided" do
      candidates = [{:channel_assignment, "999"}]

      # Call with 1 arg (uses default Agent module via line 243)
      assert is_nil(CommunicationBridge.first_active_selection(candidates))

      # Also call with explicit Zaq.Agent to exercise the default resolution path
      assert is_nil(CommunicationBridge.first_active_selection(candidates, Zaq.Agent))
    end
  end
end
