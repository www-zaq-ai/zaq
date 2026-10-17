defmodule Zaq.Channels.LinkedDevice.LifecycleTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.TestSupport.LinkedDeviceLifecycle

  test "each replacement lifecycle source is monitored and stale exits cannot disconnect it" do
    config = config()

    pid =
      start_supervised!({State, bridge_id: "whatsapp_42", config: config, provider: :whatsapp})

    first = start_supervised!({Agent, fn -> :first end}, id: :first)
    second = start_supervised!({Agent, fn -> :second end}, id: :second)

    payload = %{
      profile: profile(42),
      attempt_id: make_ref(),
      status: :pairing,
      qr: "private"
    }

    deliver(pid, first, payload)
    assert %{phase: :pairing} = State.ingress_status(pid)
    first_ref = :sys.get_state(pid).lifecycle_monitor
    assert is_reference(first_ref)
    assert {:monitors, monitors} = Process.info(pid, :monitors)
    assert {:process, first} in monitors

    :erlang.trace(pid, true, [:receive])
    stop_supervised(:first)
    assert_receive {:trace, ^pid, :receive, {:DOWN, ^first_ref, :process, ^first, _}}
    assert %{phase: :disconnected, qr: nil} = State.ingress_status(pid)

    replacement = %{payload | attempt_id: make_ref(), status: :connected, qr: nil}
    deliver(pid, second, replacement)
    assert %{phase: :connected} = State.ingress_status(pid)
    second_ref = :sys.get_state(pid).lifecycle_monitor
    refute second_ref == first_ref

    send(pid, {:DOWN, first_ref, :process, first, :killed})
    assert %{phase: :connected} = State.ingress_status(pid)

    stop_supervised(:second)
    assert_receive {:trace, ^pid, :receive, {:DOWN, ^second_ref, :process, ^second, _}}
    assert %{phase: :disconnected, qr: nil} = State.ingress_status(pid)
    :erlang.trace(pid, false, [:receive])
  end

  test "listener exits cannot overwrite the current lifecycle source status" do
    config = config()

    pid =
      start_supervised!({State, bridge_id: "whatsapp_42", config: config, provider: :whatsapp})

    listener = start_supervised!({Agent, fn -> :listener end})
    State.monitor_listeners(pid, [listener])

    payload = %{
      profile: profile(42),
      attempt_id: make_ref(),
      status: :connected,
      qr: nil
    }

    deliver(pid, self(), payload)
    assert %{phase: :connected} = State.ingress_status(pid)
    [{ref, ^listener}] = Map.to_list(:sys.get_state(pid).listener_monitors)
    :erlang.trace(pid, true, [:receive])
    stop_supervised(Agent)
    assert_receive {:trace, ^pid, :receive, {:DOWN, ^ref, :process, ^listener, _}}
    assert %{phase: :connected} = State.ingress_status(pid)
    :erlang.trace(pid, false, [:receive])
  end

  test "a replacement event ahead of a queued old DOWN retains its status" do
    config = config()

    pid =
      start_supervised!({State, bridge_id: "whatsapp_42", config: config, provider: :whatsapp})

    first = start_supervised!({Agent, fn -> :first end}, id: :first)
    second = start_supervised!({Agent, fn -> :second end}, id: :second)

    payload = %{
      profile: profile(42),
      attempt_id: make_ref(),
      status: :connected,
      qr: nil
    }

    deliver(pid, first, payload)
    assert %{phase: :connected} = State.ingress_status(pid)
    old_ref = :sys.get_state(pid).lifecycle_monitor

    replacement = %{payload | attempt_id: make_ref()}
    deliver(pid, second, replacement)
    assert :sys.get_state(pid).lifecycle_source == first

    :sys.suspend(pid)

    envelope = LinkedDeviceLifecycle.envelope(second, replacement)
    request = :gen_server.send_request(pid, {:process_listener_payload, config, envelope, []})

    try do
      stop_supervised(:first)
    after
      :sys.resume(pid)
    end

    assert {:reply, :ok} = :gen_server.receive_response(request, 1_000)

    assert :sys.get_state(pid).lifecycle_source == second
    send(pid, {:DOWN, old_ref, :process, first, :shutdown})
    assert %{phase: :connected} = State.ingress_status(pid)
    assert {:monitors, monitors} = Process.info(pid, :monitors)
    assert {:process, second} in monitors
    refute {:process, first} in monitors
  end

  test "lifecycle is profile and attempt scoped, survives config refresh and clears expired QR" do
    config = config()

    pid =
      start_supervised!({State, bridge_id: "whatsapp_42", config: config, provider: :whatsapp})

    attempt = make_ref()

    event = %{
      profile: profile(42),
      attempt_id: attempt,
      event: :qr,
      status: :pairing,
      qr: "private"
    }

    deliver(pid, self(), event)
    assert %{phase: :pairing, qr: "private"} = State.ingress_status(pid)
    assert :ok = State.refresh_config(pid, config)
    assert %{phase: :pairing, qr: "private"} = State.ingress_status(pid)
    deliver(pid, self(), %{event | attempt_id: make_ref(), qr: "stale"})

    deliver(pid, self(), %{event | profile: profile(99), qr: "foreign"})

    assert %{qr: "private"} = State.ingress_status(pid)
    deliver(pid, self(), %{event | status: :expired, qr: nil})
    assert %{phase: :expired, qr: nil} = State.ingress_status(pid)
    deliver(pid, self(), %{event | status: :connected, qr: nil})
    assert %{phase: :connected, qr: nil} = State.ingress_status(pid)
    refute inspect(:sys.get_status(pid)) =~ "private"
  end

  defp deliver(pid, source, payload) do
    config = config()
    envelope = LinkedDeviceLifecycle.envelope(source, payload)
    State.process_listener_payload(pid, config, envelope, [])
  end

  defp config,
    do: %{
      id: 42,
      provider: "whatsapp",
      settings: %{"credential_document_id" => 1},
      url: "",
      token: ""
    }

  defp profile(id) do
    Adapter.connection_options(%{channel_config_id: id, credential_id: 1},
      context: :runtime,
      sink_mfa: JidoChatBridge.storage_sink(%{provider: "whatsapp"})
    ).profile
  end
end

defmodule Zaq.Channels.LinkedDevice.RestartTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.TestSupport.WhatsAppFlowAdapter
  alias Zaq.TestSupport.WhatsAppFlowTransport, as: Transport

  test "fresh connection processes restore two accounts and disabling one preserves the other" do
    previous = Application.fetch_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      whatsapp: %{
        bridge: JidoChatBridge,
        adapter: WhatsAppFlowAdapter,
        ingress_mode: :linked_device
      }
    })

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:zaq, :channels, value)
        :error -> Application.delete_env(:zaq, :channels)
      end
    end)

    start_supervised!({Transport, observer: self()})
    # Exercise cold provider bootstrap instead of relying on application startup
    # or another supervision test to leave shared storage running.
    assert Zaq.Channels.Supervisor.stop_bridge_runtime(%{}, "provider:whatsapp") in [
             :ok,
             {:error, :not_running}
           ]

    assert :ok = JidoChatBridge.start_runtime({:provider, :whatsapp}, [])

    first = connector()
    second = connector()

    on_exit(fn ->
      JidoChatBridge.stop_runtime(first)
      JidoChatBridge.stop_runtime(second)
    end)

    for config <- [first, second] do
      assert :ok = JidoChatBridge.start_runtime(config)
      assert_receive {:whatsapp_connected_config, options}
      assert options.profile == profile(config)
      refute options.sync_history
      refute options.sync_full_history
      assert phase(config, :pairing)
      {:ok, %{qr: qr}} = JidoChatBridge.channel_ingress_status(config)
      assert :ok = Transport.scan(profile(config), qr)
      assert phase(config, :connected)
    end

    {:ok, first_conn} = Transport.resolve_conn(profile: profile(first))
    {:ok, second_conn} = Transport.resolve_conn(profile: profile(second))
    assert :ok = JidoChatBridge.stop_runtime(first)
    assert :ok = JidoChatBridge.stop_runtime(second)
    refute Process.alive?(first_conn)
    refute Process.alive?(second_conn)
    stop_supervised(Transport)
    start_supervised!({Transport, observer: self()})
    assert Transport.mailbox() == %{}
    to_disable = connector()
    disabled_profile = profile(to_disable)
    _disabled_config = to_disable |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

    to_archive = connector()
    archived_profile = profile(to_archive)
    {:ok, _archived_config} = ChannelConfig.archive(to_archive)

    assert :ok =
             Supervisor.terminate_child(
               Zaq.Channels.Supervisor,
               Zaq.Channels.BridgeSupervisor
             )

    # A new VM has not loaded the adapter yet. Only unload this test wrapper;
    # never purge production modules or a running connection's code.
    on_exit(fn -> Code.ensure_loaded!(WhatsAppFlowAdapter) end)
    :code.purge(WhatsAppFlowAdapter)
    assert :code.delete(WhatsAppFlowAdapter)
    assert :code.is_loaded(WhatsAppFlowAdapter) == false

    assert {:ok, _} =
             Supervisor.restart_child(
               Zaq.Channels.Supervisor,
               Zaq.Channels.BridgeSupervisor
             )

    for config <- [first, second] do
      assert_receive {:whatsapp_connected_config, options}
      refute options.sync_history
      refute options.sync_full_history
      assert phase(config, :connected)
      assert {:ok, %{qr: nil}} = JidoChatBridge.channel_ingress_status(config)
    end

    assert {:error, :not_connected} = Transport.resolve_conn(profile: disabled_profile)
    assert {:error, :not_connected} = Transport.resolve_conn(profile: archived_profile)

    first_profile = profile(first)
    disabled = first |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    assert :ok = JidoChatBridge.sync_runtime(first, disabled)
    assert {:error, :not_connected} = Transport.resolve_conn(profile: first_profile)
    assert {:ok, remaining} = Transport.resolve_conn(profile: profile(second))
    assert Process.alive?(remaining)
    enabled = disabled |> Ecto.Changeset.change(enabled: true) |> Repo.update!()
    assert :ok = JidoChatBridge.sync_runtime(disabled, enabled)
    assert phase(enabled, :connected)
  end

  defp connector do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: Ecto.UUID.generate(),
      provider: "whatsapp",
      kind: "retrieval"
    })
    |> Repo.insert!()
  end

  defp profile(config) do
    {:ok, profile} = JidoChatBridge.connection_profile(config)
    profile
  end

  defp phase(config, expected, attempts \\ 100)
  defp phase(_, _, 0), do: false

  defp phase(config, expected, attempts) do
    case JidoChatBridge.channel_ingress_status(config) do
      {:ok, %{phase: ^expected}} ->
        true

      _ ->
        Process.sleep(5)
        phase(config, expected, attempts - 1)
    end
  end
end

defmodule Zaq.Channels.LinkedDevice.RuntimeTest do
  use Zaq.DataCase, async: false
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}
  alias Zaq.Channels.BridgeSupervisor
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.State
  alias Zaq.TestSupport.LinkedDeviceConnectionStub, as: Transport
  alias Zaq.TestSupport.LinkedDeviceFailingListener
  alias Zaq.TestSupport.LinkedDeviceLifecycle

  test "adapter owns correlated lifecycle and expiry without sending control events to chat" do
    {worker, profile} = runtime(qr_timeout: 5)
    assert_receive {:connection, ^profile, _, relay}
    send(relay, {:amarula, :connection_update, %{qr: "private-qr"}})

    assert_receive {:lifecycle,
                    %{profile: ^profile, status: :pairing, qr: "private-qr", attempt_id: attempt}}

    assert_receive {:lifecycle, %{profile: ^profile, status: :expired, qr: nil}}, 1_000
    assert %{status: :expired, qr: nil, attempt_id: ^attempt} = ConnectionWorker.status(worker)
    refute_received {:payload, _, _}
  end

  test "history is suppressed but ordinary queued messages reach the same sink" do
    {_runtime, profile} = runtime()
    assert_receive {:connection, ^profile, _, relay}

    message = %Amarula.Msg{
      id: "queued",
      channel: Amarula.Address.parse("peer@s.whatsapp.net"),
      from: Amarula.Address.parse("peer@s.whatsapp.net"),
      type: :text,
      content: "queued",
      timestamp: 1_700_000_000,
      raw: %{}
    }

    send(relay, {:amarula, :history_sync, %{messages: [%{message | id: "history"}]}})
    send(relay, {:amarula, :messages_upsert, %{messages: [message]}})
    assert_receive {:payload, %{id: "queued", text: "queued"}, _}
    refute_received {:payload, %{id: "history"}, _}
  end

  test "profiles stop independently and duplicate startup cannot steal the existing connection" do
    {_first, profile} = runtime()
    assert_receive {:connection, ^profile, original, _}
    {_second, second_profile} = runtime()
    assert_receive {:connection, ^second_profile, second_conn, _}

    assert {:error, _} =
             BridgeSupervisor.start_runtime("duplicate_#{profile}", nil, [listener(profile, [])])

    assert Process.alive?(original)
    :ok = BridgeSupervisor.stop_bridge_runtime(%{}, profile)
    refute Process.alive?(original)
    assert Process.alive?(second_conn)
  end

  test "abnormal restart updates the bridge PID and rotates the attempt" do
    {worker, profile} = runtime()
    assert_receive {:connection, ^profile, original, _}
    %{attempt_id: attempt} = ConnectionWorker.status(worker)
    GenServer.stop(worker, :test_failure)
    assert_receive {:connection, ^profile, replacement, _}, 1_000
    refute original == replacement
    refute Process.alive?(original)
    # Synchronize with completion of the DynamicSupervisor child restart.
    children = DynamicSupervisor.which_children(BridgeSupervisor)

    assert {:ok, %{listener_pids: [replacement_worker]}} =
             BridgeSupervisor.lookup_runtime(profile)

    refute replacement_worker == worker
    assert List.keymember?(children, replacement_worker, 1)
    refute ConnectionWorker.status(replacement_worker).attempt_id == attempt
    assert :ok = BridgeSupervisor.stop_bridge_runtime(%{}, profile)
    refute Process.alive?(replacement_worker)
    refute Process.alive?(replacement)
  end

  test "failed listener startup leaves no runtime" do
    listener = %{id: :failure, start: {LinkedDeviceFailingListener, :start_link, [[]]}}
    assert {:error, _} = BridgeSupervisor.start_runtime("failure", nil, [listener])
  end

  test "a restarted adapter source is monitored and its shutdown clears the QR" do
    id = System.unique_integer([:positive])
    bridge_id = "whatsapp_#{id}"
    profile = bound_profile(id)

    config = %{
      id: id,
      provider: "whatsapp",
      settings: %{"credential_document_id" => 1},
      url: "",
      token: ""
    }

    state_module = Zaq.Channels.JidoChatBridge.State

    state_spec = %{
      id: :state,
      start:
        {state_module, :start_link, [[bridge_id: bridge_id, config: config, provider: :whatsapp]]}
    }

    {:ok, listeners} =
      Adapter.listener_child_specs(bridge_id,
        ingress: %{
          mode: :linked_device,
          profile: profile,
          transport: Transport,
          config: %{profile: profile, observer: self()}
        },
        sink_mfa: {JidoChatBridge, :from_listener, [config]}
      )

    assert {:ok, %{state_pid: state, listener_pids: [worker]}} =
             BridgeSupervisor.start_runtime(bridge_id, state_spec, listeners)

    on_exit(fn -> BridgeSupervisor.stop_bridge_runtime(%{}, bridge_id) end)
    assert_receive {:connection, ^profile, _, _relay}
    GenServer.stop(worker, :test_failure)
    assert_receive {:connection, ^profile, _, relay}, 1_000
    DynamicSupervisor.which_children(BridgeSupervisor)
    assert {:ok, %{listener_pids: [replacement]}} = BridgeSupervisor.lookup_runtime(bridge_id)
    refute replacement == worker

    :erlang.trace(state, true, [:receive])
    send(relay, {:amarula, :connection_update, %{qr: "replacement-qr"}})

    assert_receive {:trace, ^state, :receive,
                    {:"$gen_call", _,
                     {:process_listener_payload, _,
                      %Jido.Chat.EventEnvelope{
                        payload: %{metadata: %{source: source, status: :pairing}}
                      }, _}}},
                   1_000

    assert %{phase: :pairing, qr: "replacement-qr"} = state_module.ingress_status(state)
    monitor = :sys.get_state(state).lifecycle_monitor
    assert is_reference(monitor)
    assert :ok = DynamicSupervisor.terminate_child(BridgeSupervisor, replacement)
    assert_receive {:trace, ^state, :receive, {:DOWN, ^monitor, :process, ^source, _}}, 1_000
    assert %{phase: :disconnected, qr: nil} = state_module.ingress_status(state)
    :erlang.trace(state, false, [:receive])
  end

  test "shared runtime status preserves pairing presentation and disconnected fallback" do
    id = System.unique_integer([:positive])
    bridge_id = "whatsapp_#{id}"

    config = %{
      id: id,
      provider: "whatsapp",
      settings: %{"credential_document_id" => 1},
      url: "",
      token: ""
    }

    assert {:ok, %{phase: :disconnected, qr: nil}} = JidoChatBridge.channel_ingress_status(config)

    spec = %{
      id: :state,
      start: {State, :start_link, [[bridge_id: bridge_id, config: config, provider: :whatsapp]]}
    }

    assert {:ok, %{state_pid: state}} = BridgeSupervisor.start_runtime(bridge_id, spec, [])
    on_exit(fn -> BridgeSupervisor.stop_bridge_runtime(%{}, bridge_id) end)
    assert {:ok, %{phase: :disconnected, qr: nil}} = JidoChatBridge.channel_ingress_status(config)

    envelope =
      LinkedDeviceLifecycle.envelope(self(), %{
        profile: bound_profile(id),
        attempt_id: make_ref(),
        status: :pairing,
        qr: "private-qr"
      })

    assert :ok = State.process_listener_payload(state, config, envelope, [])

    assert %{phase: :pairing} = State.ingress_status(state)

    assert {:ok, %{mode: "linked_device", phase: :pairing, qr: "private-qr"}} =
             JidoChatBridge.channel_ingress_status(config)

    assert :ok = DynamicSupervisor.terminate_child(BridgeSupervisor, state)
    assert {:ok, %{phase: :disconnected, qr: nil}} = JidoChatBridge.channel_ingress_status(config)
  end

  defmodule DelayedListener do
    def start_link(owner) do
      send(owner, {:listener_starting, self()})

      receive do
        :finish_startup -> Agent.start_link(fn -> :listener end)
      end
    end
  end

  test "startup lifecycle waits for registration and preserves source and event order" do
    id = System.unique_integer([:positive])
    bridge_id = "whatsapp_#{id}"

    config = %{
      id: id,
      provider: "whatsapp",
      settings: %{"credential_document_id" => 1},
      url: "",
      token: ""
    }

    state_spec = %{
      id: :state,
      start: {State, :start_link, [[bridge_id: bridge_id, config: config, provider: :whatsapp]]}
    }

    listener_spec = %{id: :listener, start: {DelayedListener, :start_link, [self()]}}

    startup =
      Task.async(fn -> BridgeSupervisor.start_runtime(bridge_id, state_spec, [listener_spec]) end)

    assert_receive {:listener_starting, supervisor}

    on_exit(fn ->
      BridgeSupervisor.stop_bridge_runtime(%{}, bridge_id)
    end)

    owner = self()

    payload = %{
      profile:
        Adapter.connection_options(%{channel_config_id: id, credential_id: 1},
          context: :runtime,
          sink_mfa: JidoChatBridge.storage_sink(%{provider: "whatsapp"})
        ).profile,
      attempt_id: make_ref(),
      status: :pairing,
      qr: "private-qr"
    }

    dispatcher =
      start_supervised!(
        {Task,
         fn ->
           result =
             JidoChatBridge.from_listener(config, LinkedDeviceLifecycle.envelope(self(), payload),
               bridge_id: bridge_id
             )

           send(owner, {:delivered, self(), result})

           receive do
             :connected -> :ok
           end

           result =
             JidoChatBridge.from_listener(
               config,
               LinkedDeviceLifecycle.envelope(self(), %{payload | status: :connected, qr: nil}),
               bridge_id: bridge_id
             )

           send(owner, {:connected, result})

           receive do
             :stop -> :ok
           end
         end}
      )

    # Delivery must remain pending while the real listener startup holds the
    # supervisor before runtime publication; this is a bounded negative assertion.
    try do
      refute_receive {:delivered, ^dispatcher, _}, 50
    after
      send(supervisor, :finish_startup)
    end

    assert {:ok, %{state_pid: state}} = Task.await(startup)
    assert_receive {:delivered, ^dispatcher, :ok}, 1_000
    assert %{phase: :pairing, qr: "private-qr"} = State.ingress_status(state)
    assert :sys.get_state(state).lifecycle_source == dispatcher
    send(dispatcher, :connected)
    assert_receive {:connected, :ok}
    assert %{phase: :connected, qr: nil} = State.ingress_status(state)
  end

  @tag timeout: 10_000
  test "a runtime that never registers returns a terminal readiness error" do
    config = %{id: 999_999_998, provider: "whatsapp", settings: %{}}

    assert {:error, :runtime_unavailable} =
             JidoChatBridge.from_listener(config, %{}, bridge_id: "whatsapp_999999998")
  end

  defp bound_profile(id) do
    Adapter.connection_options(%{channel_config_id: id, credential_id: 1},
      context: :runtime,
      sink_mfa: JidoChatBridge.storage_sink(%{provider: "whatsapp"})
    ).profile
  end

  defp runtime(opts \\ []) do
    profile = "runtime_#{System.unique_integer([:positive])}"

    assert {:ok, %{listener_pids: [worker]}} =
             BridgeSupervisor.start_runtime(profile, nil, [listener(profile, opts)])

    on_exit(fn -> BridgeSupervisor.stop_bridge_runtime(%{}, profile) end)
    {worker, profile}
  end

  defp listener(profile, opts) do
    config =
      Map.merge(
        %{profile: profile, observer: self(), sync_history: false, sync_full_history: false},
        Map.new(opts)
      )

    {:ok, [spec]} =
      Adapter.listener_child_specs(profile,
        ingress: %{mode: :linked_device, profile: profile, transport: Transport, config: config},
        sink_mfa: {Transport, :deliver, [self()]}
      )

    spec
  end
end

defmodule Zaq.Channels.JidoChatBridge.StorageTest do
  use Zaq.DataCase, async: true

  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.Storage.{Mnesia, Split}
  alias Jido.Chat.WhatsApp.Transport.GuardedStorage
  alias Split, as: Storage
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.Grant
  alias Zaq.Event
  alias Zaq.NodeRouter

  test "shared bridge child specs enforce trusted storage and lifecycle callbacks" do
    config = connector()

    config = %{
      config
      | settings: %{
          "jido_chat" => %{
            "ingress" => %{
              "profile" => "foreign",
              "storage_root" => "/tmp/untrusted",
              "config" => %{"sync_history" => true, "sync_full_history" => true}
            }
          }
        }
    }

    runtime_config = ChannelConfig.to_runtime_config(config)

    assert {:ok, {_state, [spec]}} = JidoChatBridge.build_runtime_specs(runtime_config)
    assert {Jido.Chat.WhatsApp.ConnectionWorker, :start_link, [opts]} = spec.start
    {:ok, binding} = bind(config.id)
    assert opts[:config].profile == connection_options(binding).profile
    refute opts[:config].sync_history
    refute opts[:config].sync_full_history
    refute Map.has_key?(opts[:config], :storage_root)
    assert {Split, storage_opts} = opts[:config].storage
    assert storage_opts[:context].channel_config_id == config.id

    assert {JidoChatBridge, :from_listener, [_, capability]} = storage_opts[:sink_mfa]

    assert is_reference(capability)
    refute Keyword.has_key?(opts, :lifecycle_sink_mfa)
    assert {JidoChatBridge, :from_listener, [^config, capability]} = opts[:sink_mfa]
    assert is_reference(capability)
  end

  test "provisioning is idempotent and persisted terms survive a new callback instance" do
    config = connector()
    assert {:ok, binding} = bind(config.id)
    assert {:ok, ^binding} = bind(config.id)
    %{profile: profile, storage: {Storage, opts}} = connection_options(binding)
    storage = Storage.new(opts)
    value = %{private: <<255, 0, 10>>, nested: {:paired, [1, 2]}}
    assert :ok = Storage.put(storage, profile, :creds, :self, value)
    restored = Storage.new(opts)
    assert {:ok, ^value} = Storage.get(restored, profile, :creds, :self)
    assert {:ok, [:self]} = Storage.list_keys(restored, profile, :creds)
    assert {:ok, [^profile]} = Storage.list_profiles(restored)
    assert {:error, :invalid_profile} = Storage.get(restored, "other", :creds, :self)
    assert :ok = Storage.delete(restored, profile, :creds, :self)
    assert :error = Storage.get(restored, profile, :creds, :self)
    assert :ok = Storage.clear(restored, profile)
    assert Connect.get_credential!(binding.credential_id).auth_kind == "api_key"
  end

  test "disabled and revoked access fails without recreating a grant" do
    config = connector()
    {:ok, binding} = bind(config.id)
    %{profile: profile, storage: {Storage, opts}} = connection_options(binding)
    storage = Storage.new(opts)
    disabled = Repo.update!(Ecto.Changeset.change(config, enabled: false))
    assert {:error, :connector_unavailable} = bind(config.id)
    assert {:error, :connector_unavailable} = Storage.get(storage, profile, :creds, :self)
    Repo.update!(Ecto.Changeset.change(disabled, enabled: true))
    {:ok, _} = Connect.revoke_credential_grant(binding.credential_id, :org)
    assert {:error, :credential_revoked} = bind(config.id)
    assert {:error, :credential_revoked} = Storage.put(storage, profile, :creds, :self, %{})
  end

  test "confirmation batch and subsequent adapter writes share the package encoding" do
    actor = %{
      user_id: Zaq.AccountsFixtures.super_admin_fixture(%{must_change_password: false}).id
    }

    value = %{private: <<255, 0, 10>>, nested: {:paired, [1, 2]}}

    assert {:ok, %{runtime: _config, binding: binding}} =
             JidoChatBridge.persist_authentication("whatsapp", actor, %{
               attempt_id: Ecto.UUID.generate(),
               account: %{external_id: "+15550001", display_name: nil},
               credentials:
                 Split.encode_records(%{{:creds, :self} => value, {:prekey, 42} => <<0, 255>>})
             })

    %{profile: profile, storage: {Storage, opts}} = connection_options(binding)
    storage = Storage.new(opts)
    assert {:ok, ^value} = Storage.get(storage, profile, :creds, :self)
    assert {:ok, <<0, 255>>} = Storage.get(storage, profile, :prekey, 42)
    count = Repo.aggregate(Oban.Job, :count)
    assert :ok = Storage.put(storage, profile, :creds, :self, value)
    assert Repo.aggregate(Oban.Job, :count) == count
  end

  test "the real adapter guard latches failed durable writes and notifies its connection" do
    config = connector()
    {:ok, binding} = bind(config.id)
    %{profile: profile, storage: storage} = connection_options(binding)

    guard =
      GuardedStorage.new(
        storage: storage,
        notify: self()
      )

    assert :ok =
             GuardedStorage.put(guard, profile, :creds, :self, %{
               paired: true
             })

    Repo.update!(Ecto.Changeset.change(config, enabled: false))

    assert {:error, :storage_failed} =
             GuardedStorage.put(guard, profile, :creds, :self, %{
               paired: true
             })

    refute GuardedStorage.healthy?(guard)
    assert_received {:amarula, :error, :storage_failed}
  end

  test "messaging updates stay in RAM without changing the credential or its notifications" do
    {storage, profile, binding} = storage()
    assert :ok = Storage.put(storage, profile, :creds, :self, %{paired: true})
    grant = Repo.get_by!(Grant, credential_id: binding.credential_id)
    jobs = Repo.aggregate(Oban.Job, :count)

    for namespace <- [:session, :sender_key] do
      assert :ok = Storage.put(storage, profile, namespace, "peer", %{counter: 1})
      assert :ok = Storage.put(storage, profile, namespace, "peer", %{counter: 2})
      assert {:ok, %{counter: 2}} = Storage.get(storage, profile, namespace, "peer")
      assert {:ok, ["peer"]} = Storage.list_keys(storage, profile, namespace)

      assert {:ok, []} =
               Connect.credential_document(%{
                 op: :list_keys,
                 binding: binding,
                 namespace: to_string(namespace)
               })
    end

    assert Repo.get!(Grant, grant.id) == grant
    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert :ok = Storage.put(storage, profile, :creds, :self, %{paired: true, prekeys: [1]})
    refute Repo.get!(Grant, grant.id).api_key == grant.api_key
  end

  test "RAM callbacks retain current-binding checks and isolate accounts" do
    {storage, profile, binding} = storage()
    {other, other_profile, other_binding} = storage()
    assert :ok = Storage.put(storage, profile, :session, "peer", "first")
    assert :ok = Storage.put(other, other_profile, :session, "peer", "second")
    assert {:error, :invalid_profile} = Storage.get(storage, other_profile, :session, "peer")

    forged = %{storage | context: %{binding | credential_id: other_binding.credential_id}}
    assert {:error, :invalid_binding} = Storage.get(forged, profile, :session, "peer")
    config = Repo.get!(ChannelConfig, binding.channel_config_id)
    disabled = Repo.update!(Ecto.Changeset.change(config, enabled: false))
    assert {:error, :connector_unavailable} = Storage.get(storage, profile, :session, "peer")

    assert {:error, :connector_unavailable} =
             Storage.put(storage, profile, :session, "peer", "bad")

    Repo.update!(Ecto.Changeset.change(disabled, enabled: true))
    assert {:ok, "first"} = Storage.get(storage, profile, :session, "peer")
    assert :ok = Storage.clear(storage, profile)
    assert :error = Storage.get(storage, profile, :session, "peer")
    assert {:ok, "second"} = Storage.get(other, other_profile, :session, "peer")
    {:ok, _} = Connect.revoke_credential_grant(other_binding.credential_id, :org)
    assert {:error, :credential_revoked} = Storage.get(other, other_profile, :session, "peer")
    assert {:error, :credential_revoked} = Storage.delete(other, other_profile, :session, "peer")
    assert {:error, :credential_revoked} = Storage.list_keys(other, other_profile, :session)
  end

  test "preparation removes legacy sessions without changing pairing or current RAM state" do
    {storage, profile, binding} = storage()
    assert :ok = Storage.put(storage, profile, :creds, :self, %{paired: true})
    assert :ok = Storage.put(storage, profile, :app_state_sync_key, "sync", "retained")
    assert :ok = Storage.put(storage, profile, :session, "peer", "current")

    for namespace <- ["session", "sender_key"] do
      assert :ok =
               Connect.credential_document(%{
                 op: :put,
                 binding: binding,
                 namespace: namespace,
                 key: "legacy",
                 value: "old"
               })
    end

    assert :ok = Storage.prepare(storage)
    jobs = Repo.aggregate(Oban.Job, :count)
    assert :ok = Storage.prepare(storage)
    assert Repo.aggregate(Oban.Job, :count) == jobs
    assert {:ok, %{paired: true}} = Storage.get(storage, profile, :creds, :self)
    assert {:ok, "retained"} = Storage.get(storage, profile, :app_state_sync_key, "sync")
    assert {:ok, "current"} = Storage.get(storage, profile, :session, "peer")

    for namespace <- ["session", "sender_key"] do
      assert {:ok, []} =
               Connect.credential_document(%{
                 op: :list_keys,
                 binding: binding,
                 namespace: namespace
               })
    end
  end

  defp storage do
    config = connector()
    {:ok, binding} = bind(config.id)
    %{profile: profile, storage: {Storage, opts}} = connection_options(binding)
    storage = Storage.new(opts)

    on_exit(fn ->
      Mnesia.clear(storage.volatile, profile)
    end)

    {storage, profile, binding}
  end

  defp connector do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: Ecto.UUID.generate(),
      provider: "whatsapp",
      kind: "retrieval"
    })
    |> Repo.insert!()
  end

  defp connection_options(binding),
    do:
      Adapter.connection_options(binding,
        context: :runtime,
        sink_mfa: JidoChatBridge.storage_sink(%{provider: "whatsapp"})
      )

  defp bind(id) do
    Event.new(%{op: :bind, channel_config_id: id}, :engine,
      opts: [action: :credential_document, confidential: true, credential_document_runtime: true]
    )
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end
end

defmodule Zaq.Channels.LinkedDevice.WhatsAppIncomingTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Channels.JidoChatBridge.Incoming

  test "privacy identity matches only the receiving profile's trusted alias" do
    message = incoming(%{to_jid: "123:7@s.whatsapp.net", mentions: ["987@lid"]})
    refute message.was_mentioned

    assert incoming(%{mentions: ["987@lid"], account_jids: ["123@s.whatsapp.net", "987:1@lid"]}).was_mentioned

    refute incoming(%{mentions: ["987@lid"], account_jids: ["456@s.whatsapp.net", "654@lid"]}).was_mentioned
  end

  test "group mention selects the receiving account and ignores another account" do
    for {recipient, expected} <- [{"123:7@s.whatsapp.net", true}, {"456@s.whatsapp.net", false}] do
      incoming =
        incoming(%{
          to_jid: recipient,
          account_jids: [recipient],
          mentions: ["123@s.whatsapp.net"]
        })

      assert incoming.was_mentioned == expected
      assert [mention] = incoming.mentions
      assert mention.is_self == expected
      refute incoming.author.is_me
    end
  end

  test "self messages and quoted messages retain distinct facts" do
    incoming = incoming(%{from_me: true, quoted: %{id: "original"}})
    assert incoming.author.is_me
    refute incoming.was_mentioned
    assert incoming.external_reply_to_id == "original"
  end

  test "room identity is evidenced and unknown broadcasts remain unknown" do
    for {room, expected} <- [
          {"room@g.us", :room},
          {"123@s.whatsapp.net", :one_to_one},
          {"123@lid", :one_to_one}
        ] do
      message = incoming(%{channel_jid: room})
      facts = Incoming.normalize(message, :whatsapp, Adapter)
      assert facts.conversation_type == expected
      assert facts.source_scope == room
      assert facts.sender_id == "peer@s.whatsapp.net"
    end

    assert {:error, _} =
             Adapter.transform_incoming(%{
               id: "broadcast",
               channel_jid: "status@broadcast",
               text: "ignored"
             })
  end

  test "missing recipient never invents a self mention" do
    refute incoming(%{to_jid: nil, mentions: ["123@s.whatsapp.net"]}).was_mentioned
  end

  defp incoming(overrides) do
    payload =
      Map.merge(
        %{
          id: "message-1",
          channel_jid: "room@g.us",
          from_jid: "peer@s.whatsapp.net",
          to_jid: "123@s.whatsapp.net",
          text: "hello",
          timestamp: 1_760_000_000
        },
        overrides
      )

    {:ok, incoming} = Adapter.transform_incoming(payload)
    incoming
  end
end
