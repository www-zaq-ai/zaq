defmodule Zaq.Engine.Workflows.ShutdownRegistryRaceTest do
  # The run registry can stop *while* `interrupt_in_flight_runs/1` is selecting
  # from it. Nothing in `Registry.select/2` lets a test pause between its table
  # lookup and its `:ets.select/2`, so this drives the real race instead: a
  # tight reader loop against a real `Registry` that is shut down underneath it.
  #
  # While a registry is stopping, its tables are already deleted (so `select`
  # raises `ArgumentError`) but its supervisor process is still alive and
  # registered under the name. A "is the registry still registered/alive?" check
  # right after the failure therefore misreads that as a live registry and
  # re-raises. The invariant
  # asserted here — never raises, returns `:ok` — holds on every iteration of a
  # correct implementation, so a passing run is not flaky; a faulty
  # implementation fails on (nearly) every iteration.
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows

  @iterations 200

  # Runs in a process without SQL Sandbox ownership, so reaching the database
  # (registry still alive) raises `DBConnection.OwnershipError`; the loop just
  # retries until the registry is gone and the call settles.
  # Tells `notify` once the registry has been read at least once, so the test
  # stops it only while the reader is genuinely looping on it.
  defp spin_until_settled(registry, notify) do
    Workflows.interrupt_in_flight_runs(registry: registry)
  rescue
    DBConnection.OwnershipError ->
      if notify, do: send(notify, {:spinning, self()})
      spin_until_settled(registry, nil)
  end

  defp race_once(registry) do
    parent = self()

    {:ok, registry_pid} = Registry.start_link(keys: :unique, name: registry)
    Process.unlink(registry_pid)
    registry_ref = Process.monitor(registry_pid)

    {reader, reader_ref} =
      spawn_monitor(fn ->
        outcome =
          try do
            {:ok, spin_until_settled(registry, parent)}
          rescue
            exception -> {:raised, exception}
          end

        send(parent, {:outcome, self(), outcome})
      end)

    assert_receive {:spinning, ^reader}, 5_000
    Process.exit(registry_pid, :shutdown)
    assert_receive {:DOWN, ^registry_ref, :process, ^registry_pid, _}, 5_000

    receive do
      {:outcome, ^reader, outcome} ->
        Process.demonitor(reader_ref, [:flush])
        outcome

      {:DOWN, ^reader_ref, :process, ^reader, reason} ->
        {:exit, reason}
    after
      5_000 -> flunk("reader did not settle")
    end
  end

  test "a registry that stops during enumeration never surfaces an error" do
    outcomes =
      for i <- 1..@iterations do
        race_once(:"race_registry_#{System.unique_integer([:positive])}_#{i}")
      end

    assert Enum.frequencies(outcomes) == %{{:ok, :ok} => @iterations}
  end
end
