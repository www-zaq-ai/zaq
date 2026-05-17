defmodule Zaq.Channels.BridgeTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.Bridge
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.{CommunicationBridge, DataSourceBridge}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Repo

  defmodule StubConversations do
    def persist_from_incoming(incoming, metadata) do
      send(self(), {:stub_persist, incoming, metadata})
      :ok
    end
  end

  defmodule StubNodeRouter do
    def dispatch(event) do
      send(self(), {:dispatch_called, event})
      %{event | response: :ok}
    end
  end

  defmodule StubAgentSelection do
    def get_conversation_enabled_agent(10), do: {:error, :conversation_disabled}
    def get_conversation_enabled_agent(20), do: {:ok, %{id: 20}}
    def get_conversation_enabled_agent(_), do: {:error, :agent_not_found}
  end

  defmodule PassThroughBridge do
    def handle_from_listener(config, payload, sink_opts), do: {:ok, {config, payload, sink_opts}}
  end

  defmodule HookedBridge do
    def before_incoming(config, payload, sink_opts, _bridge_module) do
      {:ok,
       {Map.put(config, :hooked, true), Map.put(payload, "hooked", true),
        Keyword.put(sink_opts, :hooked, true)}}
    end

    def after_incoming(_config, _payload, _sink_opts, {:ok, {_c, _p, _s}}, _bridge_module),
      do: :ok

    def handle_from_listener(config, payload, sink_opts), do: {:ok, {config, payload, sink_opts}}
  end

  defmodule ErrorBeforeHookBridge do
    def before_incoming(_config, _payload, _sink_opts, _bridge_module), do: {:error, :blocked}
    def handle_from_listener(_config, _payload, _sink_opts), do: :ok
  end

  defmodule RuntimeSupervisorAlreadyRunning do
    def stop_bridge_runtime(_config, _bridge_id), do: :ok
    def start_runtime(_bridge_id, _state_spec, _listeners), do: {:error, :already_running}
  end

  defmodule RuntimeSupervisorNotRunning do
    def stop_bridge_runtime(_config, _bridge_id), do: {:error, :not_running}
    def start_runtime(_bridge_id, _state_spec, _listeners), do: {:ok, self()}
  end

  defmodule RuntimeSupervisorStartError do
    def stop_bridge_runtime(_config, _bridge_id), do: :ok
    def start_runtime(_bridge_id, _state_spec, _listeners), do: {:error, :start_failed}
  end

  defmodule RuntimeSupervisorStopError do
    def stop_bridge_runtime(_config, _bridge_id), do: {:error, :stop_failed}
    def start_runtime(_bridge_id, _state_spec, _listeners), do: {:ok, self()}
  end

  defmodule RuntimeSupervisorOtherStopError do
    def stop_bridge_runtime(_config, _bridge_id), do: {:error, :boom}
    def start_runtime(_bridge_id, _state_spec, _listeners), do: {:ok, self()}
  end

  defmodule BridgeWithoutBuildRuntimeSpecs do
    def runtime_supervisor_module, do: RuntimeSupervisorAlreadyRunning
    def runtime_bridge_id(_config), do: "bridge-1"
  end

  defmodule RestartableBridgeStartOk do
    def runtime_supervisor_module, do: RuntimeSupervisorNotRunning
    def runtime_bridge_id(_config), do: "bridge-1"
    def build_runtime_specs(_config), do: {:ok, {%{state: :ok}, []}}
  end

  defmodule RestartableBridgeStartError do
    def runtime_supervisor_module, do: RuntimeSupervisorStartError
    def runtime_bridge_id(_config), do: "bridge-1"
    def build_runtime_specs(_config), do: {:ok, {%{state: :ok}, []}}
  end

  defmodule RestartableBridgeStopError do
    def runtime_supervisor_module, do: RuntimeSupervisorStopError
    def runtime_bridge_id(_config), do: "bridge-1"
    def build_runtime_specs(_config), do: {:ok, {%{state: :ok}, []}}
  end

  defmodule RestartableBridgeBuildError do
    def runtime_supervisor_module, do: RuntimeSupervisorAlreadyRunning
    def runtime_bridge_id(_config), do: "bridge-1"
    def build_runtime_specs(_config), do: {:error, :bad_specs}
  end

  defmodule UnsupportedRouteBridge do
  end

  defmodule NoRuntimeBridge do
  end

  defmodule RestartableBridgeOtherStopError do
    def runtime_supervisor_module, do: RuntimeSupervisorOtherStopError
    def runtime_bridge_id(_config), do: "bridge-1"
    def build_runtime_specs(_config), do: {:ok, {%{state: :ok}, []}}
  end

  defmodule SyncProviderBridge do
    def sync_provider_runtime(config) do
      send(self(), {:sync_provider_runtime_called, config.provider, config.enabled})
      :ok
    end
  end

  defmodule FallbackRuntimeBridge do
    def start_runtime(config) do
      send(self(), {:fallback_start_runtime_called, config.provider, config.enabled})
      :ok
    end

    def stop_runtime(config) do
      send(self(), {:fallback_stop_runtime_called, config.provider, config.enabled})
      :ok
    end
  end

  defmodule FalseBeforeHookBridge do
    def before_incoming(_config, _payload, _sink_opts, _bridge_module), do: false
  end

  defmodule UnknownErrorBridge do
    def before_incoming(_config, _payload, _sink_opts, _bridge_module), do: :unexpected_format
  end

  defmodule CapabilitySnapshotBridge do
    def capability_snapshot(_config) do
      {:ok,
       %{
         required: [:text, :image, :streaming],
         resolved: %{:text => true, "image" => false},
         labels: %{text: "Text Support"}
       }}
    end
  end

  defmodule StringKeyCapabilityBridge do
    def capability_snapshot(_config) do
      {:ok,
       %{
         required: [:text, :image],
         resolved: %{"text" => true}
       }}
    end
  end

  defmodule NonListUnsupportedBridge do
    def capability_snapshot(_config) do
      {:ok,
       %{
         required: [:text, :image],
         resolved: %{text: true},
         unsupported: "not_a_list"
       }}
    end
  end

  defmodule NonMapValueBridge do
    def capability_snapshot(_config) do
      {:ok,
       %{
         required: [:text, :image],
         resolved: :not_a_map,
         labels: "also_not_a_map"
       }}
    end
  end

  setup do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      mattermost: %{bridge: SyncProviderBridge},
      email: %{bridge: FallbackRuntimeBridge}
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
      name: "bridge-cfg-#{provider}-#{unique}",
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

  defmodule RestartableBridge do
    def runtime_supervisor_module, do: RuntimeSupervisorAlreadyRunning
    def runtime_bridge_id(config), do: "bridge-#{config[:id] || config["id"]}"
    def build_runtime_specs(_config), do: {:ok, {%{state: :ok}, []}}
  end

  test "calls override conversations module directly" do
    incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}
    metadata = %{answer: "ok"}

    assert :ok = Bridge.persist_from_incoming(incoming, metadata, StubConversations, %{id: "u1"})
    assert_received {:stub_persist, ^incoming, ^metadata}
  end

  test "dispatches through node router for default conversations module" do
    incoming = %Incoming{content: "hello", channel_id: "chan-1", provider: :mattermost}

    metadata = %{
      answer: "response",
      confidence_score: 0.9,
      latency_ms: 10,
      prompt_tokens: 1,
      completion_tokens: 1,
      total_tokens: 2
    }

    assert :ok =
             Bridge.persist_from_incoming(
               incoming,
               metadata,
               Zaq.Engine.Conversations,
               %{id: "user-1", provider: :mattermost},
               StubNodeRouter
             )

    assert_received {:dispatch_called, event}
    assert event.next_hop.destination == :engine
    assert event.opts[:action] == :persist_from_incoming
  end

  test "first_active_selection/2 returns first conversation-enabled candidate" do
    candidates = [
      {:channel_assignment, 10},
      {:provider_default, 20},
      {:global_default, 30}
    ]

    assert %{"agent_id" => 20, "source" => "provider_default"} =
             CommunicationBridge.first_active_selection(candidates, StubAgentSelection)
  end

  test "route_incoming/4 default hooks pass through inputs" do
    config = %{provider: "email:imap"}
    payload = %{"body_text" => "hello"}
    sink_opts = [mailbox: "INBOX"]

    assert {:ok, {^config, ^payload, ^sink_opts}} =
             Bridge.route_incoming(PassThroughBridge, config, payload, sink_opts)
  end

  test "route_incoming/4 applies override hooks and after hook result" do
    assert :ok =
             Bridge.route_incoming(
               HookedBridge,
               %{provider: "email:imap"},
               %{"body_text" => "hello"},
               mailbox: "INBOX"
             )
  end

  test "route_incoming/4 propagates before hook errors" do
    assert {:error, :blocked} =
             Bridge.route_incoming(
               ErrorBeforeHookBridge,
               %{provider: "email:imap"},
               %{"body_text" => "hello"},
               mailbox: "INBOX"
             )
  end

  test "route_incoming/4 returns unsupported when bridge lacks listener handler" do
    assert {:error, :unsupported} =
             Bridge.route_incoming(
               UnsupportedRouteBridge,
               %{provider: "email:imap"},
               %{"body_text" => "hello"},
               mailbox: "INBOX"
             )
  end

  test "ack_from_event_response/1 normalizes ack values" do
    assert :ok = Bridge.ack_from_event_response(:ok)
    assert :ok = Bridge.ack_from_event_response(%{ack: :ok})
    assert :ok = Bridge.ack_from_event_response(%{"ack" => {:ok, :queued}})
    assert {:error, :no_ack} = Bridge.ack_from_event_response({:error, :no_ack})
    assert {:error, {:invalid_ack, :queued}} = Bridge.ack_from_event_response(:queued)
  end

  test "restart_runtime/2 normalizes already running to :ok" do
    assert :ok = Bridge.restart_runtime(RestartableBridge, %{id: 1, provider: "mattermost"})
  end

  test "stop_runtime_normalized/2 normalizes not_running to :ok" do
    assert :ok = Bridge.stop_runtime_normalized(RestartableBridgeStartOk, %{id: 1})
  end

  test "restart_runtime/2 returns unsupported when bridge has no build_runtime_specs" do
    assert {:error, :unsupported} =
             Bridge.restart_runtime(BridgeWithoutBuildRuntimeSpecs, %{id: 1})
  end

  test "restart_runtime/2 returns stop errors" do
    assert {:error, :stop_failed} = Bridge.restart_runtime(RestartableBridgeStopError, %{id: 1})
  end

  test "restart_runtime/2 returns build specs errors" do
    assert {:error, :bad_specs} = Bridge.restart_runtime(RestartableBridgeBuildError, %{id: 1})
  end

  test "restart_runtime/2 returns start errors" do
    assert {:error, :start_failed} = Bridge.restart_runtime(RestartableBridgeStartError, %{id: 1})
  end

  test "dispatch_provider_runtime_sync/2 uses sync_provider_runtime when available" do
    assert :ok =
             Bridge.dispatch_provider_runtime_sync(SyncProviderBridge, %{
               provider: "mattermost",
               enabled: true
             })

    assert_received {:sync_provider_runtime_called, "mattermost", true}
  end

  test "dispatch_provider_runtime_sync/2 falls back to start/stop runtime hooks" do
    assert :ok =
             Bridge.dispatch_provider_runtime_sync(FallbackRuntimeBridge, %{
               provider: "email",
               enabled: true
             })

    assert :ok =
             Bridge.dispatch_provider_runtime_sync(FallbackRuntimeBridge, %{
               provider: "email",
               enabled: false
             })

    assert_received {:fallback_start_runtime_called, "email", true}
    assert_received {:fallback_stop_runtime_called, "email", false}
  end

  test "dispatch_provider_runtime_sync/2 returns :ok when fallback bridge lacks runtime hooks" do
    assert :ok =
             Bridge.dispatch_provider_runtime_sync(NoRuntimeBridge, %{
               provider: "mattermost",
               enabled: true
             })
  end

  test "dispatch_provider_runtime_sync/2 returns no_bridge when fallback cannot resolve provider" do
    assert_raise WithClauseError, fn ->
      Bridge.dispatch_provider_runtime_sync(NoRuntimeBridge, %{provider: "slack", enabled: true})
    end
  end

  test "provider mapping and bridge resolution helpers" do
    assert Bridge.provider_to_bridge_key("email:smtp") == :email
    assert Bridge.provider_to_bridge_key("email:imap") == :email
    assert is_nil(Bridge.provider_to_bridge_key("unknown-provider"))

    assert {:ok, SyncProviderBridge} = Bridge.resolve_bridge(:mattermost)
    assert {:error, {:no_bridge, "unknown-provider"}} = Bridge.resolve_bridge("unknown-provider")
  end

  test "fetch_connection_details and config fetchers" do
    insert_config(:mattermost)

    details = Bridge.fetch_connection_details(:mattermost)
    assert is_binary(details.url)
    assert is_binary(details.token)

    assert %{} == Bridge.fetch_connection_details(:web)

    assert {:ok, _cfg} = Bridge.fetch_channel_config(:mattermost)
    assert {:ok, _cfg_any} = Bridge.fetch_any_channel_config(:mattermost)
    assert {:error, {:channel_not_configured, :slack}} = Bridge.fetch_channel_config(:slack)
    assert {:error, {:channel_not_configured, :slack}} = Bridge.fetch_any_channel_config(:slack)
  end

  test "default_bridge_id supports atom and string keys" do
    assert Bridge.default_bridge_id(%{provider: "mattermost", id: 42}) == "mattermost_42"
    assert Bridge.default_bridge_id(%{"provider" => "mattermost", "id" => 43}) == "mattermost_43"
  end

  test "stop_runtime_normalized and restart_runtime propagate non-normalized stop errors" do
    assert {:error, :boom} =
             Bridge.stop_runtime_normalized(RestartableBridgeOtherStopError, %{
               provider: "mattermost"
             })

    assert {:error, :boom} =
             Bridge.restart_runtime(RestartableBridgeOtherStopError, %{provider: "mattermost"})
  end

  test "persist_from_incoming returns node router response and ack normalizes event response" do
    incoming = %Incoming{content: "hello", channel_id: "chan-1", provider: :mattermost}
    metadata = %{answer: "ok"}

    response =
      Bridge.persist_from_incoming(
        incoming,
        metadata,
        Zaq.Engine.Conversations,
        %{id: "u1", provider: :mattermost},
        StubNodeRouter
      )

    assert response == :ok
    event = Event.new(%{ok: true}, :channels)
    assert :ok = Bridge.ack_from_event_response(%{event | response: :ok})
  end

  test "sync_config_runtime and sync_provider_runtime delegate to CommunicationBridge" do
    insert_config(:mattermost)

    assert :ok = Bridge.sync_config_runtime(nil, %{provider: "mattermost", enabled: false})
    assert :ok = Bridge.sync_provider_runtime(:mattermost)
  end

  describe "route_incoming error handling" do
    test "returns unsupported when before hook returns false" do
      assert {:error, :unsupported} =
               Bridge.route_incoming(
                 FalseBeforeHookBridge,
                 %{provider: "test"},
                 %{"body" => "hi"},
                 []
               )
    end

    test "passes through unknown error formats" do
      assert :unexpected_format =
               Bridge.route_incoming(
                 UnknownErrorBridge,
                 %{provider: "test"},
                 %{"body" => "hi"},
                 []
               )
    end
  end

  describe "data source capabilities" do
    test "required_capabilities returns data source capabilities" do
      assert Bridge.required_capabilities(:data_source) ==
               DataSourceBridge.required_capabilities()
    end

    test "capability_meta returns data source labels" do
      assert Bridge.capability_meta(:data_source) ==
               DataSourceBridge.capability_meta()
    end

    test "capability_snapshot normalizes with unsupported detection" do
      channels = Application.get_env(:zaq, :channels)

      Application.put_env(
        :zaq,
        :channels,
        Map.put(channels, :google_drive, %{bridge: CapabilitySnapshotBridge})
      )

      insert_config(:google_drive, %{kind: "data_source"})

      assert {:ok, snapshot} = Bridge.capability_snapshot(:google_drive)
      assert snapshot.kind == :data_source
      assert snapshot.required == [:text, :image, :streaming]
      # image resolved to false → unsupported; streaming missing from resolved → unsupported
      assert snapshot.unsupported == [:image, :streaming]
      assert snapshot.resolved == %{:text => true, "image" => false}
      assert snapshot.labels[:text] == "Text Support"
    end

    test "capability_resolved handles atom and string key fallback" do
      channels = Application.get_env(:zaq, :channels)

      Application.put_env(
        :zaq,
        :channels,
        Map.put(channels, :sharepoint, %{bridge: StringKeyCapabilityBridge})
      )

      insert_config(:sharepoint, %{kind: "data_source"})

      assert {:ok, snapshot} = Bridge.capability_snapshot(:sharepoint)
      assert snapshot.resolved == %{"text" => true}
      # :text is resolved via string key fallback in capability_resolved?
      refute :text in snapshot.unsupported
      assert :image in snapshot.unsupported
    end
  end

  describe "private map helpers" do
    test "map_get_list and map_get_map handle non-list/non-map values inside snapshot" do
      channels = Application.get_env(:zaq, :channels)

      Application.put_env(
        :zaq,
        :channels,
        Map.put(channels, :discord, %{bridge: NonListUnsupportedBridge})
      )

      insert_config(:discord, %{kind: "data_source"})

      assert {:ok, snapshot} = Bridge.capability_snapshot(:discord)

      # unsupported key is "not_a_list" → map_get_list returns nil → falls through to Enum.reject
      assert :image in snapshot.unsupported
      refute :text in snapshot.unsupported
    end

    test "map_get_map handles non-map resolved/labels values" do
      channels = Application.get_env(:zaq, :channels)

      Application.put_env(
        :zaq,
        :channels,
        Map.put(channels, :telegram, %{bridge: NonMapValueBridge})
      )

      insert_config(:telegram, %{kind: "data_source"})

      assert {:ok, snapshot} = Bridge.capability_snapshot(:telegram)
      # Non-map resolved/labels → map_get_map returns nil → falls back to %{}
      assert snapshot.resolved == %{}
      assert snapshot.labels != %{}
      assert :text in snapshot.unsupported
      assert :image in snapshot.unsupported
    end
  end
end
