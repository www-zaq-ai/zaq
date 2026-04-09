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

  defmodule ThrowingHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, _payload, _ctx), do: throw(:thrown_value)
  end

  defmodule AsyncThrowingHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx) do
      if dest = Map.get(payload, :notify) do
        send(dest, :before_throw)
      end

      throw(:async_thrown)
    end
  end

  defmodule AsyncCrashingHook do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx) do
      if dest = Map.get(payload, :notify) do
        send(dest, :before_crash)
      end

      raise("async boom")
    end
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
  # dispatch_sync — Scenarios 9-16
  # ---------------------------------------------------------------------------

  # Scenario 9
  test "dispatch_sync with no hooks — returns {:ok, original_payload}" do
    payload = %{question: "hello"}
    assert {:ok, ^payload} = Hooks.dispatch_sync(:retrieval, payload, %{})
  end

  # Scenario 10
  test "dispatch_sync single hook returns {:ok, new_payload} — returns new_payload" do
    Registry.register(sync_hook(MutatingHook, [:retrieval]))

    assert {:ok, %{enriched: true}} =
             Hooks.dispatch_sync(:retrieval, %{}, %{})
  end

  # Scenario 11
  test "dispatch_sync two hooks in priority order — each mutates, second receives first's output" do
    Registry.register(sync_hook(FirstHook, [:retrieval], 10))
    Registry.register(sync_hook(SecondHook, [:retrieval], 20))

    assert {:ok, %{first: true, second: true}} =
             Hooks.dispatch_sync(:retrieval, %{}, %{})
  end

  # Scenario 12
  test "dispatch_sync hook halts — chain stops, subsequent hooks NOT called" do
    Registry.register(sync_hook(HaltingHook, [:retrieval], 10))
    Registry.register(sync_hook(AfterHaltHook, [:retrieval], 20))

    assert {:halt, _} = Hooks.dispatch_sync(:retrieval, %{}, %{})
    refute_received :should_not_be_called
  end

  # Scenario 13
  test "dispatch_sync hook returns {:error, reason} — skipped, chain continues" do
    Registry.register(sync_hook(ErrorHook, [:retrieval], 10))
    Registry.register(sync_hook(AfterErrorHook, [:retrieval], 20))

    assert {:ok, %{after_error: true}} =
             Hooks.dispatch_sync(:retrieval, %{}, %{})
  end

  # Scenario 14
  test "dispatch_sync hook raises — caught, chain continues with previous payload" do
    Registry.register(sync_hook(CrashingHook, [:retrieval], 10))
    Registry.register(sync_hook(MutatingHook, [:retrieval], 20))

    assert {:ok, %{enriched: true}} =
             Hooks.dispatch_sync(:retrieval, %{}, %{})
  end

  # Scenario 15
  test "dispatch_sync ignores async hooks — only sync hooks run" do
    Registry.register(async_hook(MutatingHook, [:retrieval]))

    payload = %{question: "hello"}
    assert {:ok, ^payload} = Hooks.dispatch_sync(:retrieval, payload, %{})
  end

  # Scenario 16
  test "dispatch_sync hook returns :ok — pass-through, payload unchanged, chain continues" do
    Registry.register(sync_hook(ObserverHook, [:retrieval], 10))
    Registry.register(sync_hook(MutatingHook, [:retrieval], 20))

    assert {:ok, %{enriched: true}} =
             Hooks.dispatch_sync(:retrieval, %{}, %{})
  end

  # ---------------------------------------------------------------------------
  # dispatch_async — Scenarios 17-24
  # ---------------------------------------------------------------------------

  # Scenario 17
  test "dispatch_async with no hooks — returns :ok" do
    assert :ok = Hooks.dispatch_async(:retrieval_complete, %{}, %{})
  end

  # Scenario 18
  test "dispatch_async sync observer called — receives correct args, returns :ok" do
    ctx = %{trace_id: "abc"}
    payload = %{data: 42, notify: self()}

    Registry.register(sync_hook(VerifyingObserver, [:retrieval_complete]))
    assert :ok = Hooks.dispatch_async(:retrieval_complete, payload, ctx)
    assert_received {:called, :retrieval_complete, ^payload, ^ctx}
  end

  # Scenario 19
  test "dispatch_async sync observer raises — caught, other observers still run" do
    Registry.register(sync_hook(CrashingHook, [:retrieval_complete], 10))
    Registry.register(sync_hook(AfterCrashObserver, [:retrieval_complete], 20))

    assert :ok = Hooks.dispatch_async(:retrieval_complete, %{notify: self()}, %{})
    assert_received :after_crash_ran
  end

  # Scenario 20
  test "dispatch_async async hook with node_role: :local — Task.start used, caller returns :ok immediately" do
    test_pid = self()
    payload = %{notify: test_pid}

    Registry.register(async_hook(AsyncHook, [:retrieval_complete], :local))

    assert :ok = Hooks.dispatch_async(:retrieval_complete, payload, %{})
    assert_receive :async_called, 1000
  end

  # Scenario 21
  test "dispatch_async async hook with node_role — NodeRouter.call is invoked inside a Task" do
    Application.put_env(:zaq, :hooks_node_router_module, FakeNodeRouter)

    Registry.register(async_hook(PassThroughHook, [:retrieval_complete], :agent))

    payload = %{data: 1, notify: self()}
    ctx = %{trace_id: "xyz"}

    assert :ok = Hooks.dispatch_async(:retrieval_complete, payload, ctx)

    assert_receive {:router_called, :agent, PassThroughHook, :handle,
                    [:retrieval_complete, ^payload, ^ctx]},
                   1000
  end

  # Scenario 22
  test "dispatch_async async hook NodeRouter call fails — error caught, caller not affected" do
    Application.put_env(:zaq, :hooks_node_router_module, FailingNodeRouter)

    Registry.register(async_hook(PassThroughHook, [:retrieval_complete], :agent))

    assert :ok = Hooks.dispatch_async(:retrieval_complete, %{}, %{})
    # Give task time to complete
    Process.sleep(50)
  end

  # Scenario 23
  test "dispatch_async mixed sync + async — sync runs in-process, async spawned, all get same payload snapshot" do
    payload = %{data: "snap", notify: self()}

    Registry.register(sync_hook(SyncCapture, [:retrieval_complete]))
    Registry.register(async_hook(AsyncHook, [:retrieval_complete], :local))

    assert :ok = Hooks.dispatch_async(:retrieval_complete, payload, %{})
    assert_receive {:sync, ^payload}
    assert_receive :async_called, 1000
  end

  # Scenario 24
  test "dispatch_async always returns :ok — even when hooks error or crash" do
    Registry.register(sync_hook(CrashingHook, [:retrieval_complete]))
    assert :ok = Hooks.dispatch_async(:retrieval_complete, %{}, %{})
  end

  # ---------------------------------------------------------------------------
  # Telemetry — Scenarios 25-28
  # ---------------------------------------------------------------------------

  # Scenario 25
  test "dispatch_sync emits :start and :stop telemetry with hook_count and duration" do
    attach_telemetry(self())
    Registry.register(sync_hook(PassThroughHook, [:retrieval]))

    Hooks.dispatch_sync(:retrieval, %{}, %{})

    assert_receive {:telemetry, [:zaq, :hooks, :dispatch, :start], %{},
                    %{event: :retrieval, mode: :sync, hook_count: 1}}

    assert_receive {:telemetry, [:zaq, :hooks, :dispatch, :stop], %{duration: duration},
                    %{event: :retrieval, mode: :sync}}

    assert is_integer(duration)
  end

  # Scenario 26
  test "dispatch_async emits :start and :stop telemetry with hook_count and duration" do
    attach_telemetry(self())
    Registry.register(sync_hook(PassThroughHook, [:retrieval_complete]))

    Hooks.dispatch_async(:retrieval_complete, %{}, %{})

    assert_receive {:telemetry, [:zaq, :hooks, :dispatch, :start], %{},
                    %{event: :retrieval_complete, mode: :async, hook_count: 1}}

    assert_receive {:telemetry, [:zaq, :hooks, :dispatch, :stop], %{duration: duration},
                    %{event: :retrieval_complete, mode: :async}}

    assert is_integer(duration)
  end

  # Scenario 27
  test "handler returning {:error, reason} emits :handler :error telemetry with correct metadata" do
    attach_telemetry(self())
    Registry.register(sync_hook(ErrorHook, [:retrieval]))

    Hooks.dispatch_sync(:retrieval, %{}, %{})

    assert_receive {:telemetry, [:zaq, :hooks, :handler, :error], %{},
                    %{event: :retrieval, handler: ErrorHook, reason: :something_went_wrong}}
  end

  # Scenario 28
  test "handler raising an exception emits :handler :error telemetry with exception as reason" do
    attach_telemetry(self())
    Registry.register(sync_hook(CrashingHook, [:retrieval]))

    Hooks.dispatch_sync(:retrieval, %{}, %{})

    assert_receive {:telemetry, [:zaq, :hooks, :handler, :error], %{},
                    %{event: :retrieval, handler: CrashingHook, reason: reason}}

    assert is_struct(reason, RuntimeError)
  end

  # ---------------------------------------------------------------------------
  # dispatch_sync — throw (catch) branch
  # ---------------------------------------------------------------------------

  # Scenario 29
  test "dispatch_sync hook throws — caught, chain continues with previous payload" do
    Registry.register(sync_hook(ThrowingHook, [:retrieval], 10))
    Registry.register(sync_hook(MutatingHook, [:retrieval], 20))

    assert {:ok, %{enriched: true}} = Hooks.dispatch_sync(:retrieval, %{}, %{})
  end

  # Scenario 30
  test "dispatch_sync hook throws — emits :handler :error telemetry with {kind, reason} as reason" do
    attach_telemetry(self())
    Registry.register(sync_hook(ThrowingHook, [:retrieval]))

    Hooks.dispatch_sync(:retrieval, %{}, %{})

    assert_receive {:telemetry, [:zaq, :hooks, :handler, :error], %{},
                    %{event: :retrieval, handler: ThrowingHook, reason: {:throw, :thrown_value}}}
  end

  # ---------------------------------------------------------------------------
  # dispatch_async observer — throw (catch) branch
  # ---------------------------------------------------------------------------

  # Scenario 31
  test "dispatch_async sync observer throws — caught, other observers still run" do
    Registry.register(sync_hook(ThrowingHook, [:retrieval_complete], 10))
    Registry.register(sync_hook(AfterCrashObserver, [:retrieval_complete], 20))

    assert :ok = Hooks.dispatch_async(:retrieval_complete, %{notify: self()}, %{})
    assert_received :after_crash_ran
  end

  # Scenario 32
  test "dispatch_async sync observer throws — emits :handler :error telemetry" do
    attach_telemetry(self())
    Registry.register(sync_hook(ThrowingHook, [:retrieval_complete]))

    Hooks.dispatch_async(:retrieval_complete, %{}, %{})

    assert_receive {:telemetry, [:zaq, :hooks, :handler, :error], %{},
                    %{
                      event: :retrieval_complete,
                      handler: ThrowingHook,
                      reason: {:throw, :thrown_value}
                    }}
  end

  # ---------------------------------------------------------------------------
  # dispatch_async local Task — rescue and catch branches
  # ---------------------------------------------------------------------------

  # Scenario 33
  test "dispatch_async async local hook raises — error caught in Task, caller not affected" do
    Registry.register(async_hook(AsyncCrashingHook, [:retrieval_complete], :local))

    payload = %{notify: self()}
    assert :ok = Hooks.dispatch_async(:retrieval_complete, payload, %{})
    assert_receive :before_crash, 1000
  end

  # Scenario 34
  test "dispatch_async async local hook throws — error caught in Task, caller not affected" do
    Registry.register(async_hook(AsyncThrowingHook, [:retrieval_complete], :local))

    payload = %{notify: self()}
    assert :ok = Hooks.dispatch_async(:retrieval_complete, payload, %{})
    assert_receive :before_throw, 1000
  end

  # Scenario 35
  test "dispatch_async async local hook raises — emits :handler :error telemetry from Task" do
    attach_telemetry(self())
    Registry.register(async_hook(AsyncCrashingHook, [:retrieval_complete], :local))

    Hooks.dispatch_async(:retrieval_complete, %{}, %{})

    assert_receive {:telemetry, [:zaq, :hooks, :handler, :error], %{},
                    %{event: :retrieval_complete, handler: AsyncCrashingHook, reason: reason}},
                   1000

    assert is_struct(reason, RuntimeError)
  end

  # ---------------------------------------------------------------------------
  # documented_events/0
  # ---------------------------------------------------------------------------

  # Scenario 36
  test "documented_events/0 returns a non-empty list of atoms" do
    events = Hooks.documented_events()
    assert is_list(events)
    assert [_ | _] = events
    assert Enum.all?(events, &is_atom/1)
  end

  # Scenario 37
  test "documented_events/0 includes all known dispatch sites" do
    events = Hooks.documented_events()
    assert :retrieval in events
    assert :retrieval_complete in events
    assert :answering in events
    assert :answer_generated in events
    assert :pipeline_complete in events
    assert :embedding_reset in events
    assert :feedback_provided in events
    assert :reply_received in events
  end

  # Scenario 38
  test "every event in documented_events/0 has a matching section header in Zaq.Hooks moduledoc" do
    # Ensures @documented_events and the prose documentation stay in sync.
    # Uses Code.fetch_docs/1 to retrieve the compiled moduledoc string.
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _metadata, _docs} =
      Code.fetch_docs(Hooks)

    Enum.each(Hooks.documented_events(), fn event ->
      # Moduledoc headers use backtick-wrapped atoms, e.g. "#### `:retrieval`"
      expected_header = "#### `:#{event}`"

      assert String.contains?(moduledoc, expected_header),
             "Expected moduledoc to contain '#{expected_header}' for documented event :#{event}"
    end)
  end
end
