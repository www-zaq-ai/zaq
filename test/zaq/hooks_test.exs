defmodule Zaq.HooksTest do
  use ExUnit.Case, async: false

  alias Zaq.Hooks
  alias Zaq.Hooks.{Hook, Registry}

  # ---------------------------------------------------------------------------
  # Inline handler stubs
  # ---------------------------------------------------------------------------

  defmodule PassThroughHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx), do: {:ok, payload}
  end

  defmodule MutatingHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx), do: {:ok, Map.put(payload, :enriched, true)}
  end

  defmodule HaltingHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx), do: {:halt, payload}
  end

  defmodule ErrorHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, _payload, _ctx), do: {:error, :something_went_wrong}
  end

  defmodule CrashingHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, _payload, _ctx), do: raise("boom")
  end

  defmodule ObserverHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, _payload, _ctx), do: :ok
  end

  defmodule AsyncHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx) do
      if dest = Map.get(payload, :notify) do
        send(dest, :async_called)
      end

      :ok
    end
  end

  defmodule VerifyingObserver do
    @behaviour Zaq.Hooks.Handler
    def handle(event, payload, ctx) do
      if dest = Map.get(payload, :notify) do
        send(dest, {:called, event, payload, ctx})
      end

      :ok
    end
  end

  defmodule AfterCrashObserver do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx) do
      if dest = Map.get(payload, :notify) do
        send(dest, :after_crash_ran)
      end

      :ok
    end
  end

  defmodule FakeNodeRouter do
    def call(role, handler, fun, args) do
      # Extract test_pid from the payload argument (3rd element of args: [event, payload, ctx])
      payload = Enum.at(args, 1, %{})

      if dest = Map.get(payload, :notify) do
        send(dest, {:router_called, role, handler, fun, args})
      end

      :ok
    end
  end

  defmodule FailingNodeRouter do
    def call(_role, _handler, _fun, _args), do: raise("rpc failed")
  end

  defmodule SyncCapture do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx) do
      if dest = Map.get(payload, :notify) do
        send(dest, {:sync, payload})
      end

      :ok
    end
  end

  defmodule FirstHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx), do: {:ok, Map.put(payload, :first, true)}
  end

  defmodule SecondHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx), do: {:ok, Map.put(payload, :second, true)}
  end

  defmodule AfterHaltHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, _payload, _ctx) do
      send(self(), :should_not_be_called)
      {:ok, %{}}
    end
  end

  defmodule AfterErrorHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx), do: {:ok, Map.put(payload, :after_error, true)}
  end

  # ---------------------------------------------------------------------------
  # Setup — start a fresh Registry for each test and clear app env on exit
  # ---------------------------------------------------------------------------

  setup do
    name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    Application.put_env(:zaq, :hooks_registry_name, name)

    on_exit(fn ->
      Application.delete_env(:zaq, :hooks_registry_name)
      Application.delete_env(:zaq, :hooks_node_router_module)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp sync_hook(handler, events, priority \\ 50) do
    %Hook{handler: handler, events: events, mode: :sync, priority: priority}
  end

  defp async_hook(handler, events, node_role \\ :local) do
    %Hook{handler: handler, events: events, mode: :async, node_role: node_role}
  end

  defp attach_telemetry(test_pid) do
    ref = make_ref()

    :telemetry.attach_many(
      {__MODULE__, ref},
      [
        [:zaq, :hooks, :dispatch, :start],
        [:zaq, :hooks, :dispatch, :stop],
        [:zaq, :hooks, :handler, :error]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  # ---------------------------------------------------------------------------
  # dispatch_before — Scenarios 9-16
  # ---------------------------------------------------------------------------

  # Scenario 9
  test "dispatch_before with no hooks — returns {:ok, original_payload}" do
    payload = %{question: "hello"}
    assert {:ok, ^payload} = Hooks.dispatch_before(:before_retrieval, payload, %{})
  end

  # Scenario 10
  test "dispatch_before single hook returns {:ok, new_payload} — returns new_payload" do
    Registry.register(sync_hook(MutatingHook, [:before_retrieval]))

    assert {:ok, %{enriched: true}} =
             Hooks.dispatch_before(:before_retrieval, %{}, %{})
  end

  # Scenario 11
  test "dispatch_before two hooks in priority order — each mutates, second receives first's output" do
    Registry.register(sync_hook(FirstHook, [:before_retrieval], 10))
    Registry.register(sync_hook(SecondHook, [:before_retrieval], 20))

    assert {:ok, %{first: true, second: true}} =
             Hooks.dispatch_before(:before_retrieval, %{}, %{})
  end

  # Scenario 12
  test "dispatch_before hook halts — chain stops, subsequent hooks NOT called" do
    Registry.register(sync_hook(HaltingHook, [:before_retrieval], 10))
    Registry.register(sync_hook(AfterHaltHook, [:before_retrieval], 20))

    assert {:halt, _} = Hooks.dispatch_before(:before_retrieval, %{}, %{})
    refute_received :should_not_be_called
  end

  # Scenario 13
  test "dispatch_before hook returns {:error, reason} — skipped, chain continues" do
    Registry.register(sync_hook(ErrorHook, [:before_retrieval], 10))
    Registry.register(sync_hook(AfterErrorHook, [:before_retrieval], 20))

    assert {:ok, %{after_error: true}} =
             Hooks.dispatch_before(:before_retrieval, %{}, %{})
  end

  # Scenario 14
  test "dispatch_before hook raises — caught, chain continues with previous payload" do
    Registry.register(sync_hook(CrashingHook, [:before_retrieval], 10))
    Registry.register(sync_hook(MutatingHook, [:before_retrieval], 20))

    assert {:ok, %{enriched: true}} =
             Hooks.dispatch_before(:before_retrieval, %{}, %{})
  end

  # Scenario 15
  test "dispatch_before ignores async hooks — only sync hooks run" do
    Registry.register(async_hook(MutatingHook, [:before_retrieval]))

    payload = %{question: "hello"}
    assert {:ok, ^payload} = Hooks.dispatch_before(:before_retrieval, payload, %{})
  end

  # Scenario 16
  test "dispatch_before hook returns :ok — pass-through, payload unchanged, chain continues" do
    Registry.register(sync_hook(ObserverHook, [:before_retrieval], 10))
    Registry.register(sync_hook(MutatingHook, [:before_retrieval], 20))

    assert {:ok, %{enriched: true}} =
             Hooks.dispatch_before(:before_retrieval, %{}, %{})
  end

  # ---------------------------------------------------------------------------
  # dispatch_after — Scenarios 17-24
  # ---------------------------------------------------------------------------

  # Scenario 17
  test "dispatch_after with no hooks — returns :ok" do
    assert :ok = Hooks.dispatch_after(:after_retrieval, %{}, %{})
  end

  # Scenario 18
  test "dispatch_after sync observer called — receives correct args, returns :ok" do
    ctx = %{trace_id: "abc"}
    payload = %{data: 42, notify: self()}

    Registry.register(sync_hook(VerifyingObserver, [:after_retrieval]))
    assert :ok = Hooks.dispatch_after(:after_retrieval, payload, ctx)
    assert_received {:called, :after_retrieval, ^payload, ^ctx}
  end

  # Scenario 19
  test "dispatch_after sync observer raises — caught, other observers still run" do
    Registry.register(sync_hook(CrashingHook, [:after_retrieval], 10))
    Registry.register(sync_hook(AfterCrashObserver, [:after_retrieval], 20))

    assert :ok = Hooks.dispatch_after(:after_retrieval, %{notify: self()}, %{})
    assert_received :after_crash_ran
  end

  # Scenario 20
  test "dispatch_after async hook with node_role: :local — Task.start used, caller returns :ok immediately" do
    test_pid = self()
    payload = %{notify: test_pid}

    Registry.register(async_hook(AsyncHook, [:after_retrieval], :local))

    assert :ok = Hooks.dispatch_after(:after_retrieval, payload, %{})
    assert_receive :async_called, 1000
  end

  # Scenario 21
  test "dispatch_after async hook with node_role — NodeRouter.call is invoked inside a Task" do
    Application.put_env(:zaq, :hooks_node_router_module, FakeNodeRouter)

    Registry.register(async_hook(PassThroughHook, [:after_retrieval], :agent))

    payload = %{data: 1, notify: self()}
    ctx = %{trace_id: "xyz"}

    assert :ok = Hooks.dispatch_after(:after_retrieval, payload, ctx)

    assert_receive {:router_called, :agent, PassThroughHook, :handle,
                    [:after_retrieval, ^payload, ^ctx]},
                   1000
  end

  # Scenario 22
  test "dispatch_after async hook NodeRouter call fails — error caught, caller not affected" do
    Application.put_env(:zaq, :hooks_node_router_module, FailingNodeRouter)

    Registry.register(async_hook(PassThroughHook, [:after_retrieval], :agent))

    assert :ok = Hooks.dispatch_after(:after_retrieval, %{}, %{})
    # Give task time to complete
    Process.sleep(50)
  end

  # Scenario 23
  test "dispatch_after mixed sync + async — sync runs in-process, async spawned, all get same payload snapshot" do
    payload = %{data: "snap", notify: self()}

    Registry.register(sync_hook(SyncCapture, [:after_retrieval]))
    Registry.register(async_hook(AsyncHook, [:after_retrieval], :local))

    assert :ok = Hooks.dispatch_after(:after_retrieval, payload, %{})
    assert_receive {:sync, ^payload}
    assert_receive :async_called, 1000
  end

  # Scenario 24
  test "dispatch_after always returns :ok — even when hooks error or crash" do
    Registry.register(sync_hook(CrashingHook, [:after_retrieval]))
    assert :ok = Hooks.dispatch_after(:after_retrieval, %{}, %{})
  end

  # ---------------------------------------------------------------------------
  # Telemetry — Scenarios 25-28
  # ---------------------------------------------------------------------------

  # Scenario 25
  test "dispatch_before emits :start and :stop telemetry with hook_count and duration" do
    attach_telemetry(self())
    Registry.register(sync_hook(PassThroughHook, [:before_retrieval]))

    Hooks.dispatch_before(:before_retrieval, %{}, %{})

    assert_receive {:telemetry, [:zaq, :hooks, :dispatch, :start], %{},
                    %{event: :before_retrieval, mode: :sync, hook_count: 1}}

    assert_receive {:telemetry, [:zaq, :hooks, :dispatch, :stop], %{duration: duration},
                    %{event: :before_retrieval, mode: :sync}}

    assert is_integer(duration)
  end

  # Scenario 26
  test "dispatch_after emits :start and :stop telemetry with hook_count and duration" do
    attach_telemetry(self())
    Registry.register(sync_hook(PassThroughHook, [:after_retrieval]))

    Hooks.dispatch_after(:after_retrieval, %{}, %{})

    assert_receive {:telemetry, [:zaq, :hooks, :dispatch, :start], %{},
                    %{event: :after_retrieval, mode: :after, hook_count: 1}}

    assert_receive {:telemetry, [:zaq, :hooks, :dispatch, :stop], %{duration: duration},
                    %{event: :after_retrieval, mode: :after}}

    assert is_integer(duration)
  end

  # Scenario 27
  test "handler returning {:error, reason} emits :handler :error telemetry with correct metadata" do
    attach_telemetry(self())
    Registry.register(sync_hook(ErrorHook, [:before_retrieval]))

    Hooks.dispatch_before(:before_retrieval, %{}, %{})

    assert_receive {:telemetry, [:zaq, :hooks, :handler, :error], %{},
                    %{event: :before_retrieval, handler: ErrorHook, reason: :something_went_wrong}}
  end

  # Scenario 28
  test "handler raising an exception emits :handler :error telemetry with exception as reason" do
    attach_telemetry(self())
    Registry.register(sync_hook(CrashingHook, [:before_retrieval]))

    Hooks.dispatch_before(:before_retrieval, %{}, %{})

    assert_receive {:telemetry, [:zaq, :hooks, :handler, :error], %{},
                    %{event: :before_retrieval, handler: CrashingHook, reason: reason}}

    assert is_struct(reason, RuntimeError)
  end
end
