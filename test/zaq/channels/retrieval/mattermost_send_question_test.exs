defmodule Zaq.Channels.Retrieval.MattermostSendQuestionTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.Retrieval.Mattermost

  setup do
    Application.put_env(:zaq, :mattermost_api_module, __MODULE__.APIStub)
    Application.put_env(:zaq, :mattermost_send_question_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:zaq, :mattermost_api_module)
      Application.delete_env(:zaq, :mattermost_send_question_test_pid)
    end)

    :ok
  end

  describe "send_question/2" do
    test "calls the underlying API and returns {:ok, post_id} when API succeeds with %{\"id\" => post_id}" do
      Process.put(:api_response, {:ok, %{"id" => "post-999", "user_id" => "bot-1"}})

      assert {:ok, "post-999"} = Mattermost.send_question("channel-1", "What is the policy?")
    end

    test "returns {:ok, post_id} when API returns %{\"id\" => post_id} without user_id" do
      Process.put(:api_response, {:ok, %{"id" => "post-777"}})

      assert {:ok, "post-777"} = Mattermost.send_question("channel-2", "Any updates?")
    end

    test "returns {:error, reason} when API fails" do
      Process.put(:api_response, {:error, :timeout})

      assert {:error, :timeout} = Mattermost.send_question("channel-1", "What is the policy?")
    end

    test "returns {:error, {:unexpected_response, body}} when API returns {:ok, body} without an \"id\" key" do
      Process.put(:api_response, {:ok, %{"status" => "ok"}})

      assert {:error, {:unexpected_response, %{"status" => "ok"}}} =
               Mattermost.send_question("channel-1", "What happened?")
    end

    test "passes channel_id and question to the underlying API" do
      test_pid = self()
      Process.put(:api_response, {:ok, %{"id" => "post-321"}})

      Mattermost.send_question("my-channel", "My question text")

      assert_receive {:api_send_message_called, "my-channel", "My question text"}
    end
  end

  # ---------------------------------------------------------------------------
  # Stub
  # ---------------------------------------------------------------------------

  defmodule APIStub do
    def send_message(channel_id, message, _thread_id) do
      test_pid = Application.get_env(:zaq, :mattermost_send_question_test_pid)
      send(test_pid, {:api_send_message_called, channel_id, message})
      Process.get(:api_response, {:ok, %{"id" => "post-default"}})
    end
  end
end
