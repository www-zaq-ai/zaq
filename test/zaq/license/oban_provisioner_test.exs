defmodule Zaq.License.ObanProvisionerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Zaq.License.ObanProvisioner
  alias Zaq.Oban.DynamicCron

  # Lower log level so Logger.info messages from ObanProvisioner reach capture_log.
  # Restored on_exit so we don't pollute other test runs.
  setup do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)

    # DynamicCron is only started as an Oban plugin in runtime.exs (prod).
    # In the test env, start it under its Oban-assigned name if not already running.
    plugin_name = Oban.Registry.via(Oban, {:plugin, DynamicCron})

    unless Oban.Registry.whereis(Oban, {:plugin, DynamicCron}) do
      conf = Oban.config(Oban)
      {:ok, pid} = GenServer.start_link(DynamicCron, [conf: conf], name: plugin_name)

      on_exit(fn ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end
      end)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Feature detection / filtering
  # ---------------------------------------------------------------------------

  describe "provision/1 — feature detection" do
    test "returns ok and emits no logs for an empty module list" do
      log = capture_log(fn -> ObanProvisioner.provision([]) end)
      assert log == ""
    end

    test "skips a non-loaded atom without crashing" do
      log = capture_log(fn -> ObanProvisioner.provision([:"Zaq.AbsolutelyDoesNotExist"]) end)
      assert log == ""
    end

    test "skips a plain module that does not implement ObanFeature" do
      mod = compile_module("defmodule %MOD% do\nend")

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      refute log =~ "[ObanProvisioner]"
    end

    test "skips a module that only implements oban_queues/0 but not oban_crontab/0" do
      mod = compile_module("defmodule %MOD% do\n  def oban_queues, do: []\nend")

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      refute log =~ "[ObanProvisioner]"
    end

    test "skips a module that is missing feature_key/0" do
      mod =
        compile_module(
          "defmodule %MOD% do\n  def oban_queues, do: []\n  def oban_crontab, do: []\nend"
        )

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      refute log =~ "[ObanProvisioner]"
    end
  end

  # ---------------------------------------------------------------------------
  # Queue provisioning
  # ---------------------------------------------------------------------------

  describe "provision/1 — queue provisioning" do
    test "does nothing when feature module declares no queues" do
      mod = compile_oban_feature(queues: [], crontab: [])

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      refute log =~ "Started queue"
      refute log =~ "Failed to start queue"
    end

    test "calls Oban.start_queue for a declared queue" do
      queue = unique_queue()
      mod = compile_oban_feature(queues: [{queue, 2}], crontab: [])

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      # Either "Started queue" (success) or "Failed to start queue" (test env may not run
      # queue supervisors in inline mode) — both prove the call was attempted.
      assert log =~ "queue :#{queue}"
    end

    test "calls Oban.start_queue for each queue when multiple are declared" do
      q1 = unique_queue()
      q2 = unique_queue()
      mod = compile_oban_feature(queues: [{q1, 2}, {q2, 3}], crontab: [])

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      assert log =~ "queue :#{q1}"
      assert log =~ "queue :#{q2}"
    end

    test "merges queues across multiple feature modules" do
      q1 = unique_queue()
      q2 = unique_queue()
      mod_a = compile_oban_feature(queues: [{q1, 1}], crontab: [])
      mod_b = compile_oban_feature(queues: [{q2, 4}], crontab: [])

      log = capture_log(fn -> ObanProvisioner.provision([mod_a, mod_b]) end)
      assert log =~ "queue :#{q1}"
      assert log =~ "queue :#{q2}"
    end

    test "mixes feature modules and plain modules — only feature modules provision" do
      plain = compile_module("defmodule %MOD% do\nend")
      queue = unique_queue()
      feature = compile_oban_feature(queues: [{queue, 1}], crontab: [])

      log = capture_log(fn -> ObanProvisioner.provision([plain, feature]) end)
      assert log =~ "queue :#{queue}"
      # Only one queue attempt, not two
      refute count_occurrences(log, "[ObanProvisioner]") > 1
    end
  end

  # ---------------------------------------------------------------------------
  # Crontab handling
  # ---------------------------------------------------------------------------

  describe "provision/1 — crontab handling" do
    test "does not log cron activity when all modules return empty crontab" do
      mod = compile_oban_feature(queues: [], crontab: [])

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      refute log =~ "[DynamicCron]"
    end

    test "delegates crontab entries to DynamicCron.add_schedules/2" do
      worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker
      mod = compile_oban_feature(queues: [], crontab: [{"0 * * * *", worker}])

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      assert log =~ "[DynamicCron]"
    end

    test "uses the module's feature_key as the idempotency key" do
      worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker
      mod = compile_oban_feature(key: :test_feature, queues: [], crontab: [{"0 * * * *", worker}])

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      assert log =~ "test_feature"
    end

    test "does not call DynamicCron when crontab is empty" do
      mod = compile_oban_feature(queues: [], crontab: [])

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      refute log =~ "[DynamicCron]"
    end

    test "empty crontab does not register the feature key in DynamicCron" do
      # If the key is never registered, a future provision call with non-empty
      # crontab for the same key will correctly add the entries.
      key = :"empty_feature_#{System.unique_integer([:positive])}"
      mod = compile_oban_feature(key: key, queues: [], crontab: [])

      capture_log(fn -> ObanProvisioner.provision([mod]) end)

      pid = Oban.Registry.whereis(Oban, {:plugin, DynamicCron})
      registered = :sys.get_state(pid).registered_keys
      refute MapSet.member?(registered, key)
    end

    test "license reload — calling provision twice does not double-add crontab entries" do
      key = :"reload_feature_#{System.unique_integer([:positive])}"
      worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker
      mod = compile_oban_feature(key: key, queues: [], crontab: [{"0 * * * *", worker}])

      capture_log(fn -> ObanProvisioner.provision([mod]) end)
      capture_log(fn -> ObanProvisioner.provision([mod]) end)

      pid = Oban.Registry.whereis(Oban, {:plugin, DynamicCron})

      count =
        :sys.get_state(pid).crontab
        |> Enum.count(fn {_, _, w, _} -> w == worker end)

      assert count == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Error resilience
  # ---------------------------------------------------------------------------

  describe "provision/1 — error resilience" do
    test "does not raise when Oban.start_queue returns an error" do
      # Provision with a valid feature module — even if Oban is in inline mode
      # and start_queue behaves unexpectedly, provision/1 must not raise.
      queue = unique_queue()
      mod = compile_oban_feature(queues: [{queue, 1}], crontab: [])

      assert :ok =
               capture_log(fn -> ObanProvisioner.provision([mod]) end) |> then(fn _ -> :ok end)
    end

    test "does not raise when DynamicCron.add_schedules is called with crontab entries" do
      worker = Zaq.Engine.Telemetry.Workers.PrunePointsWorker
      mod = compile_oban_feature(queues: [], crontab: [{"0 * * * *", worker}])

      assert :ok =
               capture_log(fn -> ObanProvisioner.provision([mod]) end) |> then(fn _ -> :ok end)
    end
  end

  # ---------------------------------------------------------------------------
  # Config regression guard
  # ---------------------------------------------------------------------------

  describe "static config regression" do
    test "knowledge_gap queue is NOT declared in base Oban config" do
      base_queues =
        Application.fetch_env!(:zaq, Oban)
        |> Keyword.get(:queues, [])

      refute Keyword.has_key?(base_queues, :knowledge_gap)
    end

    test "StaleQuestionsCleanupWorker is NOT in the static Oban crontab" do
      crontab =
        Application.fetch_env!(:zaq, Oban)
        |> Keyword.get(:crontab, [])

      refute Enum.any?(crontab, fn {_expr, worker} ->
               worker == Zaq.Engine.StaleQuestionsCleanupWorker
             end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_queue do
    :"oban_prov_test_#{System.unique_integer([:positive])}"
  end

  # Compiles a module definition replacing %MOD% with a unique atom.
  # Returns the compiled module atom.
  defp compile_module(source) do
    mod_name = "Elixir.ObanProvisionerTest.M#{System.unique_integer([:positive])}"
    source = String.replace(source, "%MOD%", mod_name)
    [{mod, _}] = Code.compile_string(source)
    mod
  end

  # Compiles a module implementing Zaq.License.ObanFeature with the given
  # feature_key, queues and crontab. Crontab entries must be {expr, worker_module} tuples.
  defp compile_oban_feature(opts) do
    mod_name = "Elixir.ObanProvisionerTest.F#{System.unique_integer([:positive])}"
    key = Keyword.get(opts, :key, :"feature_#{System.unique_integer([:positive])}")
    queues = Keyword.get(opts, :queues, [])
    crontab = Keyword.get(opts, :crontab, [])

    queues_literal = inspect(queues)

    crontab_literal =
      "[" <>
        Enum.map_join(crontab, ", ", fn {expr, worker} ->
          ~s|{"#{expr}", #{inspect(worker)}}|
        end) <> "]"

    source = """
    defmodule #{mod_name} do
      @behaviour Zaq.License.ObanFeature
      def feature_key, do: #{inspect(key)}
      def oban_queues, do: #{queues_literal}
      def oban_crontab, do: #{crontab_literal}
    end
    """

    [{mod, _}] = Code.compile_string(source)
    mod
  end

  defp count_occurrences(string, substring) do
    string |> String.split(substring) |> length() |> Kernel.-(1)
  end
end
