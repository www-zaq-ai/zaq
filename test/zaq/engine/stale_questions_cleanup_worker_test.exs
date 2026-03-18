defmodule Zaq.Engine.StaleQuestionsCleanupWorkerTest do
  use ExUnit.Case, async: false

  alias Zaq.Engine.StaleQuestionsCleanupWorker

  setup do
    Application.put_env(:zaq, :pending_questions_module, __MODULE__.PendingQuestionsStub)
    Application.put_env(:zaq, :worker_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:zaq, :pending_questions_module)
      Application.delete_env(:zaq, :worker_test_pid)
      Application.delete_env(:zaq, :pending_question_ttl_seconds)
    end)

    :ok
  end

  describe "perform/1" do
    test "calls expire_stale/1 with the default TTL of 86_400 seconds" do
      assert :ok = StaleQuestionsCleanupWorker.perform(%Oban.Job{})
      assert_receive {:expire_stale_called, 86_400}
    end

    test "uses the configured pending_question_ttl_seconds app env" do
      Application.put_env(:zaq, :pending_question_ttl_seconds, 3600)

      assert :ok = StaleQuestionsCleanupWorker.perform(%Oban.Job{})
      assert_receive {:expire_stale_called, 3600}
    end

    test "returns :ok" do
      assert :ok = StaleQuestionsCleanupWorker.perform(%Oban.Job{})
    end
  end

  defmodule PendingQuestionsStub do
    def expire_stale(ttl) do
      test_pid = Application.get_env(:zaq, :worker_test_pid)
      send(test_pid, {:expire_stale_called, ttl})
      :ok
    end
  end
end
