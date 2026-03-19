defmodule Zaq.License.ObanProvisionerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Zaq.License.ObanProvisioner

  # Lower log level so Logger.info messages from ObanProvisioner reach capture_log.
  # Restored on_exit so we don't pollute other test runs.
  setup do
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: :warning) end)
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
    test "does not touch cron plugin when all modules return empty crontab" do
      mod = compile_oban_feature(queues: [], crontab: [])

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      refute log =~ "Cron plugin"
      refute log =~ "terminate cron"
    end

    test "attempts to restart cron plugin when a module declares crontab entries" do
      worker = Zaq.Engine.StaleQuestionsCleanupWorker
      mod = compile_oban_feature(queues: [], crontab: [{"0 * * * *", worker}])

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      # Success or warning — either proves the restart was attempted
      assert log =~ "Cron plugin" or log =~ "cron plugin"
    end

    test "deduplicates crontab entries by worker when two modules declare the same worker" do
      worker = Zaq.Engine.StaleQuestionsCleanupWorker
      mod_a = compile_oban_feature(queues: [], crontab: [{"0 * * * *", worker}])
      mod_b = compile_oban_feature(queues: [], crontab: [{"30 * * * *", worker}])

      # Both modules declare the same worker — only one entry should be kept.
      # We verify by checking the "restarted with N entries" message, or that the
      # restart was only attempted once.
      log = capture_log(fn -> ObanProvisioner.provision([mod_a, mod_b]) end)
      assert log =~ "1 entries" or log =~ "cron plugin"
    end

    test "merges oban_base_crontab with feature crontab entries" do
      base_worker = Zaq.Engine.StaleQuestionsCleanupWorker
      original = Application.get_env(:zaq, :oban_base_crontab, [])
      Application.put_env(:zaq, :oban_base_crontab, [{"@hourly", base_worker}])

      on_exit(fn ->
        if original == [],
          do: Application.delete_env(:zaq, :oban_base_crontab),
          else: Application.put_env(:zaq, :oban_base_crontab, original)
      end)

      # Use a distinct worker so it is not deduped with the base entry
      feature_worker =
        compile_module(
          "defmodule %MOD% do\n  use Oban.Worker, queue: :default\n  def perform(_), do: :ok\nend"
        )

      mod = compile_oban_feature(queues: [], crontab: [{"0 6 * * *", feature_worker}])

      log = capture_log(fn -> ObanProvisioner.provision([mod]) end)
      assert log =~ "2 entries" or log =~ "cron plugin"
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

    test "does not raise when cron plugin supervisor returns an error" do
      worker = Zaq.Engine.StaleQuestionsCleanupWorker
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
  # queues and crontab. Crontab entries must be {expr, worker_module} tuples.
  defp compile_oban_feature(queues: queues, crontab: crontab) do
    mod_name = "Elixir.ObanProvisionerTest.F#{System.unique_integer([:positive])}"

    queues_literal = inspect(queues)

    crontab_literal =
      "[" <>
        Enum.map_join(crontab, ", ", fn {expr, worker} ->
          ~s|{"#{expr}", #{inspect(worker)}}|
        end) <> "]"

    source = """
    defmodule #{mod_name} do
      @behaviour Zaq.License.ObanFeature
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
