defmodule Zaq.Hooks.RegistryTest do
  use ExUnit.Case, async: false

  alias Zaq.Hooks.{Hook, Registry}

  # Each test starts a fresh Registry under a unique name so it does not conflict
  # with the application-level Zaq.Hooks.Registry already running.
  # The ETS table is destroyed when the Registry process is shut down after each test.
  setup do
    name = :"#{__MODULE__}.#{System.unique_integer([:positive])}"
    start_supervised!({Registry, name: name})
    Application.put_env(:zaq, :hooks_registry_name, name)
    on_exit(fn -> Application.delete_env(:zaq, :hooks_registry_name) end)
    {:ok, registry_name: name}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp hook(handler, events, opts \\ []) do
    %Hook{
      handler: handler,
      events: events,
      mode: Keyword.get(opts, :mode, :sync),
      priority: Keyword.get(opts, :priority, 50)
    }
  end

  # Minimal handler stubs (inline modules)
  defmodule HandlerA do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx), do: {:ok, payload}
  end

  defmodule HandlerB do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx), do: {:ok, payload}
  end

  defmodule HandlerC do
    @behaviour Zaq.Hooks.Handler
    def handle(_event, payload, _ctx), do: {:ok, payload}
  end

  # ---------------------------------------------------------------------------
  # Scenario 1 — register for one event
  # ---------------------------------------------------------------------------

  test "register a hook for one event — lookup returns it" do
    h = hook(HandlerA, [:after_retrieval])
    Registry.register(h)
    assert [^h] = Registry.lookup(:after_retrieval)
  end

  # ---------------------------------------------------------------------------
  # Scenario 2 — register for multiple events
  # ---------------------------------------------------------------------------

  test "register a hook for multiple events — appears in each lookup" do
    h = hook(HandlerA, [:before_retrieval, :after_retrieval])
    Registry.register(h)
    assert [^h] = Registry.lookup(:before_retrieval)
    assert [^h] = Registry.lookup(:after_retrieval)
  end

  # ---------------------------------------------------------------------------
  # Scenario 3 — priority ordering
  # ---------------------------------------------------------------------------

  test "two hooks with different priorities — lower priority runs first" do
    low = hook(HandlerA, [:before_retrieval], priority: 10)
    high = hook(HandlerB, [:before_retrieval], priority: 90)

    Registry.register(high)
    Registry.register(low)

    [first, second] = Registry.lookup(:before_retrieval)
    assert first.handler == HandlerA
    assert second.handler == HandlerB
  end

  # ---------------------------------------------------------------------------
  # Scenario 4 — no duplicates (same handler, same event)
  # ---------------------------------------------------------------------------

  test "registering the same handler twice for the same event — second replaces first" do
    h1 = hook(HandlerA, [:before_retrieval], priority: 10)
    h2 = hook(HandlerA, [:before_retrieval], priority: 20)

    Registry.register(h1)
    Registry.register(h2)

    hooks = Registry.lookup(:before_retrieval)
    assert length(hooks) == 1
    assert hd(hooks).priority == 20
  end

  # ---------------------------------------------------------------------------
  # Scenario 5 — unregister removes all events
  # ---------------------------------------------------------------------------

  test "unregister a handler — all its events return []" do
    h = hook(HandlerA, [:before_retrieval, :after_retrieval])
    Registry.register(h)

    Registry.unregister(HandlerA)

    assert Registry.lookup(:before_retrieval) == []
    assert Registry.lookup(:after_retrieval) == []
  end

  # ---------------------------------------------------------------------------
  # Scenario 6 — unregister unknown handler
  # ---------------------------------------------------------------------------

  test "unregister a handler that was never registered — returns :ok, no crash" do
    assert :ok = Registry.unregister(HandlerC)
  end

  # ---------------------------------------------------------------------------
  # Scenario 7 — lookup unknown event
  # ---------------------------------------------------------------------------

  test "lookup unknown event — returns []" do
    assert Registry.lookup(:nonexistent_event) == []
  end

  # ---------------------------------------------------------------------------
  # Scenario 8 — crash and restart rebuilds ETS
  # ---------------------------------------------------------------------------

  test "registry crash and restart — ETS is rebuilt empty", %{registry_name: name} do
    h = hook(HandlerA, [:before_retrieval])
    Registry.register(h)
    assert [_] = Registry.lookup(:before_retrieval)

    # Kill the Registry process; ExUnit's supervisor will restart it
    pid = Process.whereis(name)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1000

    # Wait for the supervisor to restart the process (poll up to 1 s)
    Enum.find_value(1..20, fn _ ->
      Process.sleep(50)
      Process.whereis(name) != nil
    end)

    _ = :sys.get_state(name)

    # ETS is fresh after restart
    assert Registry.lookup(:before_retrieval) == []
  end
end
