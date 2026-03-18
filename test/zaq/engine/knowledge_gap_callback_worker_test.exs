defmodule Zaq.Engine.KnowledgeGapCallbackWorkerTest do
  use ExUnit.Case, async: false

  alias Zaq.Engine.KnowledgeGapCallbackWorker

  setup do
    Application.put_env(:zaq, :knowledge_gap_module, __MODULE__.KnowledgeGapStub)
    Application.put_env(:zaq, :worker_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:zaq, :knowledge_gap_module)
      Application.delete_env(:zaq, :worker_test_pid)
    end)

    :ok
  end

  describe "perform/1" do
    test "calls knowledge_gap_module.resolve/3 with question_id, answer, and table_name" do
      job = %Oban.Job{args: %{"question_id" => 42, "answer" => "Because of X."}}

      assert :ok = KnowledgeGapCallbackWorker.perform(job)
      assert_receive {:resolve_called, 42, "Because of X.", "chunks"}
    end

    test "uses the configured knowledge_gap_table app env" do
      Application.put_env(:zaq, :knowledge_gap_table, "custom_table")

      on_exit(fn -> Application.delete_env(:zaq, :knowledge_gap_table) end)

      job = %Oban.Job{args: %{"question_id" => 7, "answer" => "Yes."}}

      assert :ok = KnowledgeGapCallbackWorker.perform(job)
      assert_receive {:resolve_called, 7, "Yes.", "custom_table"}
    end

    test "returns {:error, reason} when resolve fails" do
      Application.put_env(:zaq, :knowledge_gap_module, __MODULE__.FailingKnowledgeGapStub)

      job = %Oban.Job{args: %{"question_id" => 99, "answer" => "Bad answer."}}

      assert {:error, :ingestion_failed} = KnowledgeGapCallbackWorker.perform(job)
    end

    test "returns :ok when resolve succeeds" do
      job = %Oban.Job{args: %{"question_id" => 1, "answer" => "Great answer."}}

      assert :ok = KnowledgeGapCallbackWorker.perform(job)
    end
  end

  defmodule KnowledgeGapStub do
    def resolve(question_id, answer, table_name) do
      test_pid = Application.get_env(:zaq, :worker_test_pid)
      send(test_pid, {:resolve_called, question_id, answer, table_name})
      {:ok, :resolved}
    end
  end

  defmodule FailingKnowledgeGapStub do
    def resolve(_question_id, _answer, _table_name) do
      {:error, :ingestion_failed}
    end
  end
end
