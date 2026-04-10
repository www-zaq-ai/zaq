defmodule Zaq.Oban.DynamicCronTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Oban.Job
  alias Zaq.Oban.DynamicCron
  alias Zaq.Repo

  # We start an isolated GenServer per test (via pid) so tests don't interfere
  # with the real DynamicCron plugin running in the app or with each other.
  # :sys.get_state/1 is used to assert crontab/registered_keys state directly.

  setup do
    conf = Oban.config(Oban)
    {:ok, conf: conf}
  end

  defp start_plugin(conf, base_crontab \\ []) do
    {:ok, pid} =
      GenServer.start_link(DynamicCron, conf: conf, crontab: base_crontab)

    on_exit(fn ->
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  defp add(pid, key, entries) do
    GenServer.call(pid, {:add_schedules, key, entries})
  end

  defp state(pid), do: :sys.get_state(pid)

  defp worker_modules(pid) do
    pid |> state() |> Map.fetch!(:crontab) |> Enum.map(fn {_, _, w, _} -> w end)
  end

  defp crontab_size(pid), do: pid |> state() |> Map.fetch!(:crontab) |> length()

  defmodule LeaderPeer do
    @moduledoc false

    def leader?(pid, _timeout), do: GenServer.call(pid, :leader?)
    def get_leader(_pid, _timeout), do: "test@localhost"
  end

  defmodule PeerStub do
    @moduledoc false

    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

    def leader?(pid, _timeout), do: GenServer.call(pid, :leader?)
    def get_leader(_pid, _timeout), do: "test@localhost"

    @impl GenServer
    def init(opts), do: {:ok, %{leader?: Keyword.get(opts, :leader?, false)}}

    @impl GenServer
    def handle_call(:leader?, _from, state), do: {:reply, state.leader?, state}
  end

  defp start_registered_plugin(conf, base_crontab \\ []) do
    plugin_name = Oban.Registry.via(Oban, {:plugin, DynamicCron})
    {:ok, pid} = DynamicCron.start_link(conf: conf, crontab: base_crontab, name: plugin_name)

    on_exit(fn ->
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  # ---------------------------------------------------------------------------
  # add_schedules/2 — idempotency
  # ---------------------------------------------------------------------------

  describe "add_schedules/2 — idempotency" do
    test "registers entries on first call", %{conf: conf} do
      pid = start_plugin(conf)

      :ok = add(pid, :feature_a, [{"0 * * * *", Zaq.Engine.Telemetry.Workers.PrunePointsWorker}])

      assert crontab_size(pid) == 1
      assert :feature_a in state(pid).registered_keys
    end

    test "is a no-op when called again with the same feature key", %{conf: conf} do
      pid = start_plugin(conf)
      worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker

      :ok = add(pid, :feature_a, [{"0 * * * *", worker}])
      :ok = add(pid, :feature_a, [{"0 * * * *", worker}])

      assert crontab_size(pid) == 1
    end

    test "second call with same key does not alter crontab even with different entries", %{
      conf: conf
    } do
      pid = start_plugin(conf)
      worker_a = Zaq.Engine.Telemetry.Workers.PrunePointsWorker
      worker_b = Zaq.Engine.Telemetry.Workers.PushRollupsWorker

      :ok = add(pid, :feature_a, [{"0 * * * *", worker_a}])
      :ok = add(pid, :feature_a, [{"*/5 * * * *", worker_b}])

      # Only the first call's entries should be present
      workers = worker_modules(pid)
      assert worker_a in workers
      refute worker_b in workers
    end

    test "different feature keys are registered independently", %{conf: conf} do
      pid = start_plugin(conf)
      worker_a = Zaq.Engine.Telemetry.Workers.PrunePointsWorker
      worker_b = Zaq.Engine.Telemetry.Workers.PushRollupsWorker

      :ok = add(pid, :feature_a, [{"0 * * * *", worker_a}])
      :ok = add(pid, :feature_b, [{"*/5 * * * *", worker_b}])

      assert crontab_size(pid) == 2
      assert :feature_a in state(pid).registered_keys
      assert :feature_b in state(pid).registered_keys
    end
  end

  # ---------------------------------------------------------------------------
  # add_schedules/2 — same worker, multiple cron expressions
  # ---------------------------------------------------------------------------

  describe "add_schedules/2 — same worker at multiple schedules" do
    test "keeps both entries when the same worker has two different expressions", %{conf: conf} do
      pid = start_plugin(conf)
      worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker

      :ok =
        add(pid, :feature_a, [
          {"0 * * * *", worker, args: %{type: "hourly"}},
          {"0 0 * * *", worker, args: %{type: "daily"}}
        ])

      assert crontab_size(pid) == 2
      exprs = pid |> state() |> Map.fetch!(:crontab) |> Enum.map(fn {expr, _, _, _} -> expr end)
      assert "0 * * * *" in exprs
      assert "0 0 * * *" in exprs
    end

    test "keeps both entries when the same worker has different opts", %{conf: conf} do
      pid = start_plugin(conf)
      worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker

      :ok =
        add(pid, :feature_a, [
          {"0 * * * *", worker, args: %{scope: "fast"}},
          {"0 * * * *", worker, args: %{scope: "slow"}}
        ])

      assert crontab_size(pid) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # add_schedules/2 — exact duplicate deduplication
  # ---------------------------------------------------------------------------

  describe "add_schedules/2 — exact duplicate deduplication" do
    test "drops exact duplicate (same expr + worker + opts) from new entries", %{conf: conf} do
      worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker
      pid = start_plugin(conf, [{"0 * * * *", worker}])

      # Adding the exact same entry that's already in base crontab
      :ok = add(pid, :feature_a, [{"0 * * * *", worker}])

      assert crontab_size(pid) == 1
    end

    test "keeps entry from base crontab when feature provides exact same one", %{conf: conf} do
      worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker
      pid = start_plugin(conf, [{"0 * * * *", worker}])

      :ok = add(pid, :feature_a, [{"0 * * * *", worker}])

      # Base entry is kept (it was first)
      [{expr, _, w, _}] = state(pid).crontab
      assert expr == "0 * * * *"
      assert w == worker
    end
  end

  # ---------------------------------------------------------------------------
  # add_schedules/2 — base crontab interaction
  # ---------------------------------------------------------------------------

  describe "add_schedules/2 — base crontab interaction" do
    test "feature entries are added on top of base crontab", %{conf: conf} do
      base_worker = Zaq.Engine.Telemetry.Workers.AggregateRollupsWorker
      feature_worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker

      pid = start_plugin(conf, [{"* * * * *", base_worker}])
      :ok = add(pid, :feature_a, [{"0 * * * *", feature_worker}])

      assert crontab_size(pid) == 2
      workers = worker_modules(pid)
      assert base_worker in workers
      assert feature_worker in workers
    end

    test "multiple features accumulate on top of base crontab", %{conf: conf} do
      base_worker = Zaq.Engine.Telemetry.Workers.AggregateRollupsWorker
      worker_a = Zaq.Engine.Telemetry.Workers.PrunePointsWorker
      worker_b = Zaq.Engine.Telemetry.Workers.PushRollupsWorker

      pid = start_plugin(conf, [{"* * * * *", base_worker}])
      :ok = add(pid, :feature_a, [{"0 * * * *", worker_a}])
      :ok = add(pid, :feature_b, [{"*/10 * * * *", worker_b}])

      assert crontab_size(pid) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # @reboot entries
  # ---------------------------------------------------------------------------

  describe "@reboot entries" do
    test "reboot entries are parsed and present in initial crontab", %{conf: conf} do
      worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker
      pid = start_plugin(conf, [{"@reboot", worker}])

      assert crontab_size(pid) == 1
      [{_expr, parsed, ^worker, _}] = state(pid).crontab
      assert parsed.reboot?
    end

    test "reboot entries can be added alongside regular entries", %{conf: conf} do
      reboot_worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker
      regular_worker = Zaq.Engine.Telemetry.Workers.PushRollupsWorker

      pid = start_plugin(conf, [{"@reboot", reboot_worker}, {"0 * * * *", regular_worker}])

      assert crontab_size(pid) == 2

      reboot? =
        state(pid).crontab
        |> Enum.find(fn {_, _, w, _} -> w == reboot_worker end)
        |> then(fn {_, parsed, _, _} -> parsed.reboot? end)

      assert reboot?
    end

    # NOTE: discard_reboots/1 runs inside the Peer.leader? branch of handle_info(:evaluate).
    # In test mode Peer.leader? always returns false (no peer process), so the discard
    # cannot be triggered in unit tests. The behaviour is inherited from Oban.Plugins.Cron
    # and verified in production where a leader is elected.
  end

  # ---------------------------------------------------------------------------
  # Public API and callbacks
  # ---------------------------------------------------------------------------

  describe "public API and callbacks" do
    test "start_link/1 starts with custom name", %{conf: conf} do
      name = :dynamic_cron_custom_name
      {:ok, pid} = DynamicCron.start_link(conf: conf, name: name)

      on_exit(fn ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end
      end)

      assert Process.whereis(name) == pid
    end

    test "add_schedules/2 uses the registered plugin name", %{conf: conf} do
      pid = start_registered_plugin(conf)
      worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker

      assert :ok = DynamicCron.add_schedules(:public_api_feature, [{"0 * * * *", worker}])
      assert crontab_size(pid) == 1
      assert :public_api_feature in state(pid).registered_keys
    end

    test "terminate/2 returns :ok when timer is nil" do
      assert :ok = DynamicCron.terminate(:normal, %DynamicCron{timer: nil})
    end

    test "terminate/2 cancels an active timer" do
      timer = Process.send_after(self(), :dynamic_cron_timer_probe, 250)

      assert :ok = DynamicCron.terminate(:normal, %DynamicCron{timer: timer})
      refute_receive :dynamic_cron_timer_probe, 350
    end

    test "handle_info/2 logs and keeps state for unexpected message", %{conf: conf} do
      pid = start_plugin(conf)

      log =
        capture_log(fn ->
          send(pid, {:unexpected, :message})
          _ = state(pid)
        end)

      assert log =~ "[DynamicCron] Unexpected message"
    end

    test "evaluate on leader branch reschedules", %{conf: conf} do
      oban_name = :oban_dynamic_cron_leader_test
      peer_name = Oban.Registry.via(oban_name, Oban.Peer)

      {:ok, peer_pid} =
        start_supervised({PeerStub, [name: peer_name, leader?: true]})

      assert is_pid(peer_pid)

      leader_conf = %{conf | name: oban_name, peer: {LeaderPeer, []}}

      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Zaq.Repo)

      pid = start_plugin(leader_conf, [])
      {:noreply, updated} = DynamicCron.handle_info(:evaluate, state(pid))

      assert is_reference(updated.timer)
    end

    test "evaluate on non-leader branch reschedules", %{conf: conf} do
      pid = start_plugin(conf)
      {:noreply, updated} = DynamicCron.handle_info(:evaluate, state(pid))

      assert is_reference(updated.timer)
    end

    test "evaluate inserts matching jobs for leader" do
      oban_name = :oban_dynamic_cron_insert_test

      oban_opts =
        :zaq
        |> Application.fetch_env!(Oban)
        |> Keyword.merge(
          name: oban_name,
          plugins: [],
          queues: [],
          testing: :disabled,
          peer: {Oban.Peers.Isolated, [leader?: true]}
        )

      start_supervised!({Oban, oban_opts})

      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Zaq.Repo)

      dynamic_conf = Oban.config(oban_name)
      assert Oban.Peer.leader?(dynamic_conf)

      before_count = Repo.aggregate(Job, :count, :id)

      pid =
        start_plugin(dynamic_conf, [
          {"* * * * *", Zaq.Engine.Telemetry.Workers.PrunePointsWorker, args: %{from: "test"}}
        ])

      {:noreply, _updated} = DynamicCron.handle_info(:evaluate, state(pid))
      after_count = Repo.aggregate(Job, :count, :id)

      assert after_count == before_count + 1
    end
  end

  # ---------------------------------------------------------------------------
  # validate/1
  # ---------------------------------------------------------------------------

  describe "validate/1" do
    test "returns :ok for valid opts" do
      conf = Oban.config(Oban)
      assert :ok = DynamicCron.validate(conf: conf, crontab: [])
    end

    test "returns error for non-keyword opts" do
      assert {:error, _} = DynamicCron.validate("not_a_keyword")
    end

    test "returns error when crontab is not a list" do
      assert {:error, _} = DynamicCron.validate(conf: nil, crontab: :bad)
    end

    test "returns :ok when opts omit crontab" do
      conf = Oban.config(Oban)
      assert :ok = DynamicCron.validate(conf: conf)
    end
  end
end
