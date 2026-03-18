defmodule Zaq.Engine.RouterTest do
  use ExUnit.Case, async: false

  alias Zaq.Engine.Router

  setup do
    Application.put_env(:zaq, :channel_config_module, __MODULE__.ChannelConfigStub)
    Application.put_env(:zaq, :retrieval_supervisor_module, __MODULE__.RetrievalSupervisorStub)
    Application.put_env(:zaq, :pending_questions_module, __MODULE__.PendingQuestionsStub)
    Application.put_env(:zaq, :router_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:zaq, :channel_config_module)
      Application.delete_env(:zaq, :retrieval_supervisor_module)
      Application.delete_env(:zaq, :pending_questions_module)
      Application.delete_env(:zaq, :router_test_pid)
    end)

    :ok
  end

  describe "dispatch_question/3" do
    test "routes to the correct adapter resolved from ChannelConfig by provider" do
      on_answer = fn _answer -> :ok end

      {:ok, _post_id} = Router.dispatch_question("ch-mattermost", "What is ZAQ?", on_answer)

      assert_receive {:adapter_send_question_called, "ch-mattermost", "What is ZAQ?"}
    end

    test "calls adapter.send_question/2 and gets back {:ok, post_id}" do
      on_answer = fn _answer -> :ok end

      assert {:ok, "post-abc"} =
               Router.dispatch_question("ch-mattermost", "What is ZAQ?", on_answer)
    end

    test "wires PendingQuestions so the on_answer callback fires when check_reply is called" do
      test_pid = self()
      on_answer = fn answer -> send(test_pid, {:on_answer_fired, answer}) end

      assert {:ok, _post_id} =
               Router.dispatch_question("ch-mattermost", "What is ZAQ?", on_answer)

      assert_receive {:pending_questions_ask_called, "ch-mattermost", "What is ZAQ?", ^on_answer}
    end

    test "returns {:ok, post_id} on success" do
      on_answer = fn _answer -> :ok end

      assert {:ok, "post-abc"} =
               Router.dispatch_question("ch-mattermost", "A question?", on_answer)
    end

    test "returns {:error, reason} when adapter's send_question/2 fails" do
      on_answer = fn _answer -> :ok end

      assert {:error, :connection_refused} =
               Router.dispatch_question("ch-fail", "Will this work?", on_answer)
    end

    test "returns {:error, :no_adapter} when no ChannelConfig found for the given channel_id" do
      on_answer = fn _answer -> :ok end

      assert {:error, :no_adapter} =
               Router.dispatch_question("ch-unknown", "Anyone home?", on_answer)
    end
  end

  # ---------------------------------------------------------------------------
  # Stubs
  # ---------------------------------------------------------------------------

  defmodule ChannelConfigStub do
    def get_by_channel_id("ch-mattermost"), do: %{provider: "mattermost"}
    def get_by_channel_id("ch-fail"), do: %{provider: "failing_provider"}
    def get_by_channel_id(_), do: nil
  end

  defmodule RetrievalSupervisorStub do
    def adapter_for("mattermost"), do: Zaq.Engine.RouterTest.MattermostAdapterStub
    def adapter_for("failing_provider"), do: Zaq.Engine.RouterTest.FailingAdapterStub
    def adapter_for(_), do: nil
  end

  defmodule MattermostAdapterStub do
    def send_question(channel_id, question) do
      test_pid = Application.get_env(:zaq, :router_test_pid)
      send(test_pid, {:adapter_send_question_called, channel_id, question})
      {:ok, "post-abc"}
    end
  end

  defmodule FailingAdapterStub do
    def send_question(_channel_id, _question) do
      {:error, :connection_refused}
    end
  end

  defmodule PendingQuestionsStub do
    def ask(channel_id, _user_id, question, send_fn, on_answer) do
      test_pid = Application.get_env(:zaq, :router_test_pid)

      case send_fn.(channel_id, question) do
        {:ok, _} ->
          send(test_pid, {:pending_questions_ask_called, channel_id, question, on_answer})
          {:ok, "post-abc"}

        error ->
          error
      end
    end
  end
end
