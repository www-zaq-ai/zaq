defmodule Zaq.Engine.Conversations.TokenUsageAggregatorTest do
  use Zaq.DataCase, async: true
  use Oban.Testing, repo: Zaq.Repo

  @moduletag capture_log: true

  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.TokenUsageAggregator

  defp create_conv_with_assistant_msg(model, prompt_tokens, completion_tokens) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        channel_type: "bo",
        channel_user_id: "test_#{System.unique_integer([:positive])}"
      })

    {:ok, _msg} =
      Conversations.add_message(conv, %{
        role: "assistant",
        content: "Answer",
        model: model,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: prompt_tokens + completion_tokens
      })

    conv
  end

  describe "perform/1" do
    test "aggregates token usage into conversation metadata" do
      conv = create_conv_with_assistant_msg("gpt-4", 100, 50)

      assert :ok =
               perform_job(TokenUsageAggregator, %{
                 "conversation_id" => conv.id,
                 "model" => "gpt-4"
               })

      updated = Conversations.get_conversation!(conv.id)
      today = Date.utc_today() |> Date.to_iso8601()
      usage = get_in(updated.metadata, ["token_usage", today, "gpt-4"])

      assert usage["prompt_tokens"] == 100
      assert usage["completion_tokens"] == 50
      assert usage["total_tokens"] == 150
    end

    test "idempotency — running twice accumulates the same totals" do
      conv = create_conv_with_assistant_msg("gpt-4", 200, 100)

      job_args = %{"conversation_id" => conv.id, "model" => "gpt-4"}

      assert :ok = perform_job(TokenUsageAggregator, job_args)
      assert :ok = perform_job(TokenUsageAggregator, job_args)

      updated = Conversations.get_conversation!(conv.id)
      today = Date.utc_today() |> Date.to_iso8601()
      usage = get_in(updated.metadata, ["token_usage", today, "gpt-4"])

      # Should reflect actual DB totals (200+100), not doubled
      assert usage["prompt_tokens"] == 200
      assert usage["completion_tokens"] == 100
    end

    test "multiple models aggregated independently" do
      {:ok, conv} =
        Conversations.create_conversation(%{
          channel_type: "bo",
          channel_user_id: "multi_model_#{System.unique_integer([:positive])}"
        })

      {:ok, _} =
        Conversations.add_message(conv, %{
          role: "assistant",
          content: "GPT answer",
          model: "gpt-4",
          prompt_tokens: 80,
          completion_tokens: 40
        })

      {:ok, _} =
        Conversations.add_message(conv, %{
          role: "assistant",
          content: "Llama answer",
          model: "llama-3",
          prompt_tokens: 60,
          completion_tokens: 30
        })

      assert :ok =
               perform_job(TokenUsageAggregator, %{
                 "conversation_id" => conv.id,
                 "model" => "gpt-4"
               })

      assert :ok =
               perform_job(TokenUsageAggregator, %{
                 "conversation_id" => conv.id,
                 "model" => "llama-3"
               })

      updated = Conversations.get_conversation!(conv.id)
      today = Date.utc_today() |> Date.to_iso8601()

      gpt_usage = get_in(updated.metadata, ["token_usage", today, "gpt-4"])
      llama_usage = get_in(updated.metadata, ["token_usage", today, "llama-3"])

      assert gpt_usage["prompt_tokens"] == 80
      assert llama_usage["prompt_tokens"] == 60
    end
  end
end
