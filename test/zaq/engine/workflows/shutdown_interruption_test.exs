defmodule Zaq.Engine.Workflows.ShutdownInterruptionTest do
  # Exercises `Workflows.interrupt_in_flight_runs/1` against registries whose
  # lifecycle the test fully owns (private, uniquely named), so the shared
  # `RunRegistry` of the test VM is never stopped.
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows

  @valid_node %{
    name: "fetch",
    type: "action",
    module: "Zaq.Engine.Workflows.Test.InboxWithResults",
    params: %{},
    index: 0
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp running_run do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Shutdown #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [@valid_node]
      })

    {:ok, run} =
      Workflows.create_run(wf, %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "manual"},
        "trace_id" => Ecto.UUID.generate()
      })

    {:ok, run} = Workflows.update_run(run, %{status: "running"})
    run
  end

  # Registers a stand-in driver process for `run_id`. `Registry.register/3`
  # links the caller to the registry, so a separate process keeps the test
  # process out of the registry's lifecycle.
  defp register_driver(registry, run_id) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(registry, run_id, nil)
        send(parent, {:registered, self()})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp unique_registry_name, do: :"shutdown_registry_#{System.unique_integer([:positive])}"

  # Runs `fun` in a process with no `$callers` link to the test, hence no SQL
  # Sandbox ownership: any Repo access from `fun` raises an ownership error.
  defp run_without_db_access(fun) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {:result, self(), safe(fun)}) end)

    receive do
      {:result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:exit, reason}
    end
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:raised, exception}
  end

  describe "interrupt_in_flight_runs/1 when the run registry is unavailable" do
    test "never-started registry returns :ok without any database access" do
      assert {:ok, :ok} =
               run_without_db_access(fn ->
                 Workflows.interrupt_in_flight_runs(registry: unique_registry_name())
               end)
    end

    test "control: the same unowned process does hit the database when the registry is alive" do
      name = unique_registry_name()
      start_supervised!({Registry, keys: :unique, name: name})

      assert {:raised, %DBConnection.OwnershipError{}} =
               run_without_db_access(fn -> Workflows.interrupt_in_flight_runs(registry: name) end)
    end

    test "registry that terminated after use returns :ok, leaves runs untouched, no DB access" do
      name = unique_registry_name()
      pid = start_supervised!({Registry, keys: :unique, name: name}, id: name)
      run = running_run()
      register_driver(name, run.id)

      ref = Process.monitor(pid)
      :ok = stop_supervised(name)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert {:ok, :ok} =
               run_without_db_access(fn ->
                 Workflows.interrupt_in_flight_runs(registry: name)
               end)

      assert Workflows.get_run!(run.id).status == "running"
    end

    test "an ArgumentError from a live non-registry process is not swallowed" do
      name = unique_registry_name()
      start_supervised!(%{id: name, start: {Agent, :start_link, [fn -> nil end, [name: name]]}})

      assert_raise ArgumentError, fn ->
        Workflows.interrupt_in_flight_runs(registry: name)
      end
    end
  end

  describe "interrupt_in_flight_runs/1 when a registry table owner is lost" do
    # The registry supervisor stays alive and registered (suspended, so it can
    # never answer a call) while a partition that owns the key/pid tables is
    # killed. Classification must not call into the suspended supervisor.
    for partitions <- [1, 2] do
      test "dead partition under a suspended, still-alive supervisor (#{partitions} partition(s)) is unavailable" do
        name = unique_registry_name()

        registry =
          start_supervised!(
            {Registry, keys: :unique, name: name, partitions: unquote(partitions)}
          )

        partition_pids = for {_, pid, _, _} <- Supervisor.which_children(registry), do: pid
        [victim | _] = partition_pids
        victim_ref = Process.monitor(victim)

        :ok = :sys.suspend(registry)

        try do
          Process.exit(victim, :kill)
          assert_receive {:DOWN, ^victim_ref, :process, ^victim, _}
          assert Process.alive?(registry)

          assert {:ok, :ok} =
                   run_without_db_access(fn ->
                     Workflows.interrupt_in_flight_runs(registry: name)
                   end)

          assert Process.alive?(registry)
        after
          :sys.resume(registry)
        end
      end
    end

    test "all owners alive but a key table deleted by hand is a genuine fault" do
      name = unique_registry_name()
      start_supervised!({Registry, keys: :unique, name: name})

      [{-1, info}, {-2, _}] = Enum.sort(:ets.tab2list(name), :desc)
      :ets.delete(elem(info, 2))

      assert_raise ArgumentError, fn -> Workflows.interrupt_in_flight_runs(registry: name) end
    end
  end

  describe "interrupt_in_flight_runs/1 when the run registry is alive" do
    test "interrupts only locally driven runs; peer-owned and unowned runs stay running" do
      name = unique_registry_name()
      start_supervised!({Registry, keys: :unique, name: name})

      local = running_run()
      peer_or_unowned = running_run()
      register_driver(name, local.id)

      assert :ok = Workflows.interrupt_in_flight_runs(registry: name)

      assert Workflows.get_run!(local.id).status == "interrupted"
      assert Workflows.get_run!(peer_or_unowned.id).status == "running"
    end
  end
end
