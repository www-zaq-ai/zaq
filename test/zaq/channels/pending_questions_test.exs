defmodule Zaq.Channels.PendingQuestionsTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.PendingQuestions

  setup do
    start_supervised!(PendingQuestions)
    :ok
  end

  test "ask/5 tracks a pending question and check_reply resolves it" do
    fake_send = fn _channel_id, _question ->
      {:ok, %{"id" => "post_123", "user_id" => "bot_1"}}
    end

    test_pid = self()
    on_answer = fn answer -> send(test_pid, {:answered, answer}) end

    assert {:ok, "post_123"} = PendingQuestions.ask("ch1", "bot_1", "How?", fake_send, on_answer)
    assert map_size(PendingQuestions.pending()) == 1

    # Reply from a different user triggers callback
    reply = %{root_id: "post_123", user_id: "human_1", message: "Like this."}
    assert {:answered, "Like this.", callback} = PendingQuestions.check_reply(reply)
    callback.("Like this.")

    assert_receive {:answered, "Like this."}
    assert map_size(PendingQuestions.pending()) == 0
  end

  test "check_reply ignores bot's own messages" do
    fake_send = fn _channel_id, _question ->
      {:ok, %{"id" => "post_456", "user_id" => "bot_1"}}
    end

    PendingQuestions.ask("ch1", "bot_1", "Q?", fake_send, fn _ -> :ok end)

    bot_reply = %{root_id: "post_456", user_id: "bot_1", message: "self-reply"}
    assert :ignore = PendingQuestions.check_reply(bot_reply)
    assert map_size(PendingQuestions.pending()) == 1
  end

  test "check_reply ignores unrelated messages" do
    assert :ignore =
             PendingQuestions.check_reply(%{root_id: "unknown", user_id: "u1", message: "hi"})

    assert :ignore = PendingQuestions.check_reply(%{root_id: "", user_id: "u1", message: "hi"})
  end
end
