defmodule Zaq.Channels.SupervisionTest do
  use Zaq.DataCase, async: false

  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}
  alias Jido.Chat.WhatsApp.Storage.Mnesia
  alias Jido.Chat.WhatsApp.Storage.Runtime, as: SessionStorage
  alias Zaq.Channels.BridgeSupervisor
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.PeopleAuthRateLimiter, as: Ingress
  alias Zaq.Channels.Supervisor, as: Channels
  alias Zaq.Engine.ChannelConfig
  alias Zaq.TestSupport.Channels.RuntimeAdapterStub, as: StubAdapter

  defmodule TelegramAdapter do
    def ensure_ingress_subscription(_bridge_id, _opts), do: {:ok, %{}}
  end

  defmodule InvalidInfrastructure do
    def infrastructure_child_specs(_), do: raise("private configuration must not escape")
  end

  defmodule InvalidInfrastructureConfig do
    def get(:zaq, :channels, _),
      do: %{fixture: %{bridge: Zaq.Channels.WebBridge, adapter: InvalidInfrastructure}}
  end

  defmodule ExtraInfoInfrastructure do
    def infrastructure_child_specs(opts),
      do: {:ok, [%{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}]}

    def start_link(opts) do
      {:ok, pid} = Agent.start_link(fn -> :infrastructure end)
      send(opts[:owner], {:infrastructure_started, pid})
      {:ok, pid, :provider_info}
    end
  end

  defmodule ExtraInfoConfig do
    def get(:zaq, :channels, _),
      do: %{fixture: %{bridge: Zaq.Channels.WebBridge, adapter: ExtraInfoInfrastructure}}
  end

  defmodule PartialInfrastructure do
    def infrastructure_child_specs(opts) do
      {:ok,
       [
         %{id: :first, start: {ExtraInfoInfrastructure, :start_link, [opts]}},
         Keyword.get(opts, :next_spec, %{id: :second, start: {__MODULE__, :fail, []}})
       ]}
    end

    def fail, do: {:error, :fixture_failed}
  end

  defmodule PartialInfrastructureConfig do
    def get(:zaq, :channels, _),
      do: %{fixture: %{bridge: Zaq.Channels.WebBridge, adapter: PartialInfrastructure}}
  end

  defmodule StartupBridge do
    def sync_provider_runtime({:provider, :fixture}, opts) do
      send(opts[:owner], {:startup_options, opts})
      :ok
    end
  end

  defmodule StartupConfig do
    def get(:zaq, :channels, _), do: %{fixture: %{bridge: StartupBridge}}
  end

  setup do
    previous = Application.get_env(:zaq, :channels)
    Application.put_env(:zaq, :channels, Map.take(previous, [:web_widget, :whatsapp]))
    # Each crash scenario gets its own restart budget and resource ownership.
    :ok = Supervisor.terminate_child(Zaq.Supervisor, Channels)
    {:ok, _} = Supervisor.restart_child(Zaq.Supervisor, Channels)

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    :ok
  end

  test "static parent starts limiter before dynamic bridge owner and retains role discovery" do
    assert {:ok, {%{strategy: :one_for_one}, specs}} = Channels.init([])

    assert Enum.map(specs, & &1.id) == [
             Ingress,
             BridgeSupervisor
           ]

    children = Supervisor.which_children(Channels)
    assert length(children) == 2

    assert {_, widget, :supervisor, [WebWidget.Supervisor]} =
             Enum.find(DynamicSupervisor.which_children(BridgeSupervisor), fn
               {_, _, _, modules} -> modules == [WebWidget.Supervisor]
             end)

    assert widget == Process.whereis(WebWidget.Supervisor)

    assert {_, store, :supervisor, [SessionStorage]} =
             Enum.find(DynamicSupervisor.which_children(BridgeSupervisor), fn
               {_, _, _, modules} -> modules == [SessionStorage]
             end)

    assert {:ok, %{state_pid: nil, listener_pids: [^store]}} =
             Channels.lookup_runtime("provider:whatsapp")

    assert :ok = JidoChatBridge.sync_provider_runtime({:provider, :whatsapp}, [])
    assert Process.whereis(SessionStorage) == store

    assert Process.alive?(store)
    assert :mnesia.table_info(:jido_chat_whatsapp_sessions, :storage_type) == :ram_copies

    for module <- [Ingress, BridgeSupervisor] do
      assert {^module, pid, :supervisor, [^module]} = List.keyfind(children, module, 0)
      assert pid == Process.whereis(module)
    end

    assert :ets.info(:zaq_channels_listeners, :owner) == Process.whereis(Channels)
    assert Zaq.NodeRouter.supervisor_map().channels == Channels
    assert Zaq.NodeRouter.find_node(Channels) == node()
  end

  test "bridge supervisor crash reloads configured runtimes and preserves limiter counters" do
    bridge_id = configured_runtime()
    assert {:ok, old_runtime} = Channels.lookup_runtime(bridge_id)
    ingress = Process.whereis(Ingress)
    cache = Process.whereis(Ingress.Config)
    table = :ets.whereis(:zaq_channels_listeners)
    ip = exhaust_identification_budget()
    old_bridge = Process.whereis(BridgeSupervisor)
    old_storage = Process.whereis(SessionStorage)
    scope = make_ref()
    storage = Mnesia.new(scope: scope)
    assert :ok = Mnesia.put(storage, "retained", :session, "peer", "ratchet")
    on_exit(fn -> Mnesia.clear(Mnesia.new(scope: scope), "retained") end)
    {:ok, specs} = StubAdapter.listener_child_specs("ephemeral", [])
    assert {:ok, ephemeral} = Channels.start_runtime("ephemeral", nil, specs)

    crash_child(
      Channels,
      BridgeSupervisor,
      runtime_pids(old_runtime) ++ ephemeral.listener_pids
    )

    refute Process.whereis(BridgeSupervisor) == old_bridge
    refute Process.whereis(SessionStorage) == old_storage
    assert {:error, :storage_unavailable} = Mnesia.get(storage, "retained", :session, "peer")
    assert {:ok, "ratchet"} = Mnesia.get(Mnesia.new(scope: scope), "retained", :session, "peer")
    assert Process.whereis(Ingress) == ingress
    assert Process.whereis(Ingress.Config) == cache
    assert :ets.whereis(:zaq_channels_listeners) == table
    assert [] == :ets.lookup(:zaq_channels_listeners, "ephemeral")
    assert {:error, :not_running} = Channels.lookup_runtime("ephemeral")
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
    assert_reloaded(bridge_id, old_runtime)
  end

  test "unconfigured WhatsApp starts no shared storage runtime" do
    previous = Application.fetch_env!(:zaq, :channels)
    assert :ok = Supervisor.terminate_child(Channels, BridgeSupervisor)

    try do
      Application.put_env(:zaq, :channels, Map.delete(previous, :whatsapp))
      assert {:ok, _} = Supervisor.restart_child(Channels, BridgeSupervisor)
      assert Process.whereis(SessionStorage) == nil
      assert {:error, :not_running} = Channels.lookup_runtime("provider:whatsapp")
      assert Process.alive?(Process.whereis(WebWidget.Supervisor))
    after
      assert :ok = Supervisor.terminate_child(Channels, BridgeSupervisor)
      Application.put_env(:zaq, :channels, previous)
      assert {:ok, _} = Supervisor.restart_child(Channels, BridgeSupervisor)
    end
  end

  test "infrastructure startup failure rolls back the dynamic subtree" do
    :ok = Supervisor.terminate_child(Channels, BridgeSupervisor)

    try do
      assert {:error, :provider_infrastructure_start_failed} =
               BridgeSupervisor.start_link(config: InvalidInfrastructureConfig)

      assert Process.whereis(BridgeSupervisor) == nil
      assert Process.whereis(WebWidget.Supervisor) == nil
    after
      assert {:ok, _} = Supervisor.restart_child(Channels, BridgeSupervisor)
    end
  end

  test "generic infrastructure bootstrap accepts OTP extra-info startup results" do
    :ok = Supervisor.terminate_child(Channels, BridgeSupervisor)

    assert {:ok, supervisor} =
             BridgeSupervisor.start_link(
               config: ExtraInfoConfig,
               adapter_options: %{fixture: [owner: self()]}
             )

    try do
      assert_receive {:infrastructure_started, child}
      assert {_, ^child, :worker, _} = hd(DynamicSupervisor.which_children(supervisor))
      assert Process.alive?(child)
    after
      Supervisor.stop(supervisor)
      assert {:ok, _} = Supervisor.restart_child(Channels, BridgeSupervisor)
    end
  end

  test "partial provider infrastructure startup rolls back all children" do
    :ok = Supervisor.terminate_child(Channels, BridgeSupervisor)

    try do
      assert {:error, :provider_infrastructure_start_failed} =
               BridgeSupervisor.start_link(
                 config: PartialInfrastructureConfig,
                 host_options: [owner: self()]
               )

      assert_receive {:infrastructure_started, child}
      refute Process.alive?(child)
      assert Process.whereis(BridgeSupervisor) == nil
    after
      assert {:ok, _} = Supervisor.restart_child(Channels, BridgeSupervisor)
    end
  end

  test "supervisor leaves startup option interpretation to the bridge" do
    :ok = Supervisor.terminate_child(Channels, BridgeSupervisor)

    opts = [
      config: StartupConfig,
      owner: self(),
      host_options: [opaque: make_ref()],
      adapter_options: %{fixture: [opaque: :override]}
    ]

    assert {:ok, supervisor} = BridgeSupervisor.start_link(opts)

    try do
      assert_receive {:startup_options, ^opts}
    after
      Supervisor.stop(supervisor)
      assert {:ok, _} = Supervisor.restart_child(Channels, BridgeSupervisor)
    end
  end

  test "malformed OTP child specs are rejected before any runtime child starts" do
    :ok = Supervisor.terminate_child(Channels, BridgeSupervisor)

    try do
      assert {:error, :provider_infrastructure_start_failed} =
               BridgeSupervisor.start_link(
                 config: PartialInfrastructureConfig,
                 adapter_options: %{fixture: [owner: self(), next_spec: :invalid_child_module]}
               )

      refute_receive {:infrastructure_started, _}
      assert Process.whereis(BridgeSupervisor) == nil
    after
      assert {:ok, _} = Supervisor.restart_child(Channels, BridgeSupervisor)
    end
  end

  test "limiter supervisor crash preserves bridges while replacing limiter resources" do
    bridge_id = configured_runtime()
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    bridge = Process.whereis(BridgeSupervisor)
    ingress = Process.whereis(Ingress)
    cache = Process.whereis(Ingress.Config)
    ip = exhaust_identification_budget()

    crash_child(Channels, Ingress, ingress_children())

    refute Process.whereis(Ingress) == ingress
    refute Process.whereis(Ingress.Config) == cache
    assert Process.whereis(BridgeSupervisor) == bridge
    assert Channels.lookup_runtime(bridge_id) == {:ok, runtime}
    assert Enum.all?(runtime_pids(runtime), &Process.alive?/1)
    refresh_config()
    assert :ok = Ingress.check_identification(ip)
  end

  test "session store failure preserves unrelated bridges and limiter counters" do
    bridge_id = configured_runtime()
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    ingress = Process.whereis(Ingress)

    store = Process.whereis(SessionStorage)

    ip = exhaust_identification_budget()
    bridge = Process.whereis(BridgeSupervisor)

    :ok = GenServer.stop(store, :storage_failure)
    DynamicSupervisor.which_children(BridgeSupervisor)
    assert {:ok, %{listener_pids: [replacement]}} = Channels.lookup_runtime("provider:whatsapp")

    refute replacement == store
    assert Process.whereis(BridgeSupervisor) == bridge
    assert Channels.lookup_runtime(bridge_id) == {:ok, runtime}
    assert Enum.all?(runtime_pids(runtime), &Process.alive?/1)
    assert Process.whereis(Ingress) == ingress
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
  end

  for child <- [SessionStorage, Mnesia] do
    @storage_child child
    test "#{inspect(child)} outage pauses WhatsApp without restarting other channels" do
      bridge_id = configured_runtime()
      assert {:ok, unrelated} = Channels.lookup_runtime(bridge_id)
      telegram_id = configured_runtime("telegram")
      assert {:ok, telegram} = Channels.lookup_runtime(telegram_id)
      bridge = Process.whereis(BridgeSupervisor)
      store = Mnesia
      transport = Zaq.TestSupport.LinkedDeviceConnectionStub

      # More listeners than the shared supervisor restart budget.
      workers =
        for index <- 1..5 do
          profile = "storage_recovery_#{System.unique_integer([:positive])}_#{index}"

          {:ok, specs} =
            Adapter.listener_child_specs(profile,
              ingress: %{
                mode: :linked_device,
                profile: profile,
                transport: transport,
                config: %{profile: profile, observer: self(), storage: {store, scope: profile}}
              },
              sink_mfa: {transport, :deliver, [self()]}
            )

          assert {:ok, %{listener_pids: [worker]}} = Channels.start_runtime(profile, nil, specs)
          on_exit(fn -> Channels.stop_bridge_runtime(%{}, profile) end)
          assert_receive {:connection, ^profile, connection, _}
          {profile, worker, connection}
        end

      if @storage_child == SessionStorage do
        assert :ok = Channels.stop_bridge_runtime(%{}, "provider:whatsapp")
      else
        assert :ok = Supervisor.terminate_child(SessionStorage, @storage_child)
      end

      try do
        for {profile, worker, connection} <- workers do
          assert_receive {:lifecycle, %{profile: ^profile, status: :failed, qr: nil}}, 1_000
          refute Process.alive?(connection)
          assert %{status: :failed} = ConnectionWorker.status(worker)

          assert {:error, :storage_unavailable} =
                   ConnectionWorker.reconnect(worker)
        end

        # Let several readiness retries run while the dependency stays absent.
        refute_receive {:connection, _, _, _}, 350
        assert Process.whereis(BridgeSupervisor) == bridge
        assert Channels.lookup_runtime(bridge_id) == {:ok, unrelated}
        assert Enum.all?(runtime_pids(unrelated) ++ runtime_pids(telegram), &Process.alive?/1)
        assert Channels.lookup_runtime(telegram_id) == {:ok, telegram}
      after
        if @storage_child == SessionStorage do
          assert :ok = JidoChatBridge.sync_provider_runtime({:provider, :whatsapp}, [])
        else
          assert {:ok, _} = Supervisor.restart_child(SessionStorage, @storage_child)
        end
      end

      for {profile, worker, old_connection} <- workers do
        assert_receive {:connection, ^profile, connection, relay}, 2_000
        refute connection == old_connection

        assert Channels.lookup_runtime(profile) ==
                 {:ok, %{state_pid: nil, listener_pids: [worker]}}

        send(relay, {:amarula, :connection_update, %{qr: "recovered-qr"}})

        assert_receive {:lifecycle, %{profile: ^profile, status: :pairing, qr: "recovered-qr"}},
                       1_000
      end

      assert Process.whereis(BridgeSupervisor) == bridge
      assert Enum.all?(runtime_pids(unrelated) ++ runtime_pids(telegram), &Process.alive?/1)
    end
  end

  test "parent crash stops all subtrees and recreates ETS before bootstrapping" do
    bridge_id = configured_runtime()
    assert {:ok, old_runtime} = Channels.lookup_runtime(bridge_id)
    old_parent = Process.whereis(Channels)
    old_table = :ets.whereis(:zaq_channels_listeners)

    descendants =
      [
        Process.whereis(BridgeSupervisor),
        Process.whereis(Ingress),
        Process.whereis(WebWidget.Supervisor),
        Process.whereis(WebWidget.Configuration)
      ] ++
        ingress_children() ++ runtime_pids(old_runtime)

    crash_child(Zaq.Supervisor, Channels, descendants)

    refute Process.whereis(Channels) == old_parent
    refute :ets.whereis(:zaq_channels_listeners) == old_table
    assert :ets.info(:zaq_channels_listeners, :owner) == Process.whereis(Channels)
    assert_reloaded(bridge_id, old_runtime)
    refresh_config()
    assert {:ok, _} = Ingress.Config.get()
  end

  test "parent shutdown removes resources and missing-table lookups retain not_running contract" do
    bridge_id = configured_runtime()
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)

    refs =
      monitor_all([
        Process.whereis(Ingress),
        Process.whereis(WebWidget.Supervisor),
        Process.whereis(BridgeSupervisor) | runtime_pids(runtime)
      ])

    assert :ok = Supervisor.terminate_child(Zaq.Supervisor, Channels)

    try do
      assert_down(refs)
      assert :undefined == :ets.whereis(:zaq_channels_listeners)
      assert {:error, :not_running} = Channels.lookup_runtime(bridge_id)
      assert {:error, :not_running} = Channels.lookup_state_pid(bridge_id)
      assert {:error, :not_running} = Channels.stop_bridge_runtime(%{}, bridge_id)
      assert nil == Zaq.NodeRouter.find_node(Channels)
    after
      assert {:ok, _} = Supervisor.restart_child(Zaq.Supervisor, Channels)
    end

    assert_reloaded(bridge_id, runtime)
  end

  test "bridge child shutdown retains the parent table but never returns dead runtime pids" do
    bridge_id = configured_runtime()
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    refs = monitor_all(runtime_pids(runtime))
    table = :ets.whereis(:zaq_channels_listeners)
    assert :ok = Supervisor.terminate_child(Channels, BridgeSupervisor)

    try do
      assert_down(refs)
      assert :ets.whereis(:zaq_channels_listeners) == table
      assert {:error, :not_running} = Channels.lookup_runtime(bridge_id)
      assert {:error, :not_running} = Channels.lookup_state_pid(bridge_id)
      assert :ok = Channels.stop_bridge_runtime(%{}, bridge_id)
      assert {:error, :not_running} = Channels.stop_bridge_runtime(%{}, bridge_id)
      assert Zaq.NodeRouter.find_node(Channels) == node()
    after
      assert {:ok, _} = Supervisor.restart_child(Channels, BridgeSupervisor)
    end

    assert_reloaded(bridge_id, runtime)
  end

  test "OTP abnormal termination isolates sibling recovery while retaining the parent" do
    bridge_id = configured_runtime()
    assert {:ok, old_runtime} = Channels.lookup_runtime(bridge_id)
    parent = Process.whereis(Channels)
    ingress = Process.whereis(Ingress)
    bridge = Process.whereis(BridgeSupervisor)
    ip = exhaust_identification_budget()

    :ok = Supervisor.stop(bridge, :runtime_failure)
    children = Supervisor.which_children(Channels)

    assert {BridgeSupervisor, new_bridge, :supervisor, _} =
             List.keyfind(children, BridgeSupervisor, 0)

    refute new_bridge == bridge
    assert is_pid(new_bridge)
    assert Process.whereis(Ingress) == ingress
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    refute runtime.state_pid == old_runtime.state_pid

    :ok = Supervisor.stop(ingress, :limiter_failure)
    children = Supervisor.which_children(Channels)
    assert {Ingress, new_ingress, :supervisor, _} = List.keyfind(children, Ingress, 0)
    refute new_ingress == ingress
    assert is_pid(new_ingress)
    assert Process.whereis(Channels) == parent
    assert Process.whereis(BridgeSupervisor) == new_bridge
    assert Channels.lookup_runtime(bridge_id) == {:ok, runtime}
    assert Enum.all?(runtime_pids(runtime), &Process.alive?/1)
    refresh_config()
    assert :ok = Ingress.check_identification(ip)
  end

  test "a stopped state is not returned even when a listener remains alive" do
    bridge_id = configured_runtime()
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    ref = Process.monitor(runtime.state_pid)
    assert :ok = DynamicSupervisor.terminate_child(BridgeSupervisor, runtime.state_pid)
    assert_receive {:DOWN, ^ref, :process, _, :shutdown}
    assert {:ok, _} = Channels.lookup_runtime(bridge_id)
    assert {:error, :not_running} = Channels.lookup_state_pid(bridge_id)
    assert :ok = Channels.stop_bridge_runtime(%{}, bridge_id)
  end

  test "duplicate dynamic starts preserve active runtime entries" do
    bridge_id = configured_runtime()
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    bridge = Process.whereis(BridgeSupervisor)
    assert {:error, {:already_started, ^bridge}} = BridgeSupervisor.start_link([])
    assert Channels.lookup_runtime(bridge_id) == {:ok, runtime}
    assert :ok = Channels.stop_bridge_runtime(%{}, bridge_id)
  end

  test "processless runtimes preserve the empty runtime return contract" do
    assert {:ok, %{listener_pids: [], state_pid: nil} = runtime} =
             Channels.start_runtime("empty", nil)

    assert Channels.lookup_runtime("empty") == {:ok, runtime}
    assert {:error, :not_running} = Channels.lookup_state_pid("empty")
    assert :ok = Channels.stop_bridge_runtime(%{}, "empty")
  end

  defp configured_runtime(provider \\ "mattermost") do
    provider_config = %{
      bridge: JidoChatBridge,
      adapter: if(provider == "telegram", do: TelegramAdapter, else: StubAdapter),
      ingress_mode: if(provider == "telegram", do: :webhook, else: :websocket)
    }

    Application.put_env(
      :zaq,
      :channels,
      Map.put(
        Application.get_env(:zaq, :channels),
        String.to_existing_atom(provider),
        provider_config
      )
    )

    {:ok, config} =
      ChannelConfig.upsert_by_provider(provider, %{
        name: "Supervision lifecycle",
        kind: "retrieval",
        provider: provider,
        enabled: true,
        url: "https://mm.example.com",
        token: "test-token",
        settings: %{}
      })

    assert {:ok, _} = Channels.start_listener(config)
    "#{provider}_#{config.id}"
  end

  defp assert_reloaded(bridge_id, old) do
    assert {:ok, runtime} = Channels.lookup_runtime(bridge_id)
    refute runtime.state_pid == old.state_pid
    assert [_] = runtime.listener_pids
    refute runtime.listener_pids == old.listener_pids
    assert Channels.lookup_state_pid(bridge_id) == {:ok, runtime.state_pid}
    children = DynamicSupervisor.which_children(BridgeSupervisor)
    assert Enum.all?(runtime_pids(runtime), &List.keymember?(children, &1, 1))
    assert :ok = Channels.stop_bridge_runtime(%{}, bridge_id)
  end

  defp exhaust_identification_budget do
    {:ok, _} = Zaq.System.save_people_access_config(%{unknown_email_attempt_limit: 1})
    refresh_config()
    unique = System.unique_integer([:positive])
    ip = {0, 0, 0, 0, 0, 0, div(unique, 65_536), rem(unique, 65_536)}
    assert :ok = Ingress.record_failed_identification(ip)
    assert {:error, {:rate_limited, _}} = Ingress.check_identification(ip)
    ip
  end

  defp refresh_config do
    send(Ingress.Config, :refresh)
    _ = :sys.get_state(Ingress.Config)
  end

  defp runtime_pids(runtime), do: [runtime.state_pid | runtime.listener_pids]

  defp ingress_children do
    [
      Process.whereis(Ingress.Config),
      Process.whereis(Ingress.Runtime),
      Process.whereis(Ingress.Listener),
      :ets.info(Ingress.Local, :owner)
    ]
  end

  defp crash_child(parent, child, descendants) do
    pid = Process.whereis(child)
    refs = monitor_all(Enum.uniq([pid | descendants ++ subtree_pids(pid)]))
    # :kill bypasses OTP terminate callbacks. Hold restart until all linked
    # descendants release their registered names; monitor every subtree process.
    # The separate abnormal-termination test exercises unpaused OTP recovery.
    :ok = :sys.suspend(parent)

    try do
      Process.exit(pid, :kill)
      assert_down(refs)
    after
      :ok = :sys.resume(parent)
    end

    # Ordinary supervisor call is processed after the queued child exit/restart.
    assert {^child, new_pid, :supervisor, _} =
             parent |> Supervisor.which_children() |> List.keyfind(child, 0)

    refute new_pid == pid
    assert is_pid(new_pid)
  end

  defp subtree_pids(supervisor) do
    Enum.flat_map(Supervisor.which_children(supervisor), fn
      {_, pid, :supervisor, _} when is_pid(pid) -> [pid | subtree_pids(pid)]
      {_, pid, :worker, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
  end

  defp monitor_all(pids), do: Enum.map(pids, &{&1, Process.monitor(&1)})

  defp assert_down(refs) do
    for {pid, ref} <- refs do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end
end
