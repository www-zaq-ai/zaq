defmodule Zaq.Engine.Conversations.ObanEnqueueTest do
  @moduledoc """
  Tests that add_message/2 triggers TokenUsageAggregator side-effects.

  Oban is configured with `testing: :inline` in test, so jobs run synchronously
  on insert. We verify the job's side-effects (metadata updated on conversation)
  rather than asserting the job was enqueued.
  """

  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Conversations

  defp conv_attrs do
    %{channel_type: "bo", channel_user_id: "u_#{System.unique_integer([:positive])}"}
  end

  describe "add_message/2 TokenUsageAggregator side-effects" do
    test "adds token usage to conversation metadata after assistant message with model" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())

      {:ok, _msg} =
        Conversations.add_message(conv, %{
          role: "assistant",
          content: "answer",
          model: "gpt-4",
          prompt_tokens: 50,
          completion_tokens: 25
        })

      # With testing: :inline, the job runs synchronously — metadata is updated
      updated = Conversations.get_conversation!(conv.id)
      today = Date.utc_today() |> Date.to_iso8601()
      usage = get_in(updated.metadata, ["token_usage", today, "gpt-4"])

      assert usage["prompt_tokens"] == 50
      assert usage["completion_tokens"] == 25
      assert usage["total_tokens"] == 75
    end

    test "does not update token usage metadata for assistant message without model" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())

      {:ok, _msg} =
        Conversations.add_message(conv, %{role: "assistant", content: "no model"})

      updated = Conversations.get_conversation!(conv.id)
      assert updated.metadata == %{} or is_nil(get_in(updated.metadata, ["token_usage"]))
    end

    test "does not update token usage metadata for user message" do
      {:ok, conv} = Conversations.create_conversation(conv_attrs())
      {:ok, _msg} = Conversations.add_message(conv, %{role: "user", content: "question"})

      updated = Conversations.get_conversation!(conv.id)
      assert updated.metadata == %{} or is_nil(get_in(updated.metadata, ["token_usage"]))
    end
  end
end
