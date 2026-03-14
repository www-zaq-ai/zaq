defmodule Zaq.Engine.Conversations.TokenUsageAggregator do
  @moduledoc """
  Oban worker that aggregates daily token usage per conversation and model.

  Triggered after each assistant message is stored. Accumulates
  `prompt_tokens` + `completion_tokens` totals into
  `conversation.metadata["token_usage"][date][model]`.
  """

  use Oban.Worker, queue: :conversations, max_attempts: 3

  require Logger

  import Ecto.Query

  alias Zaq.Engine.Conversations.{Conversation, Message}
  alias Zaq.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"conversation_id" => conversation_id, "model" => model}}) do
    today_str = Date.utc_today() |> Date.to_iso8601()

    day_start = DateTime.new!(Date.utc_today(), ~T[00:00:00.000000], "Etc/UTC")
    day_end = DateTime.new!(Date.utc_today(), ~T[23:59:59.999999], "Etc/UTC")

    conversation = Repo.get!(Conversation, conversation_id)

    totals =
      from(m in Message,
        where:
          m.conversation_id == ^conversation_id and
            m.role == "assistant" and
            m.model == ^model and
            m.inserted_at >= ^day_start and
            m.inserted_at <= ^day_end,
        select: %{
          prompt: sum(m.prompt_tokens),
          completion: sum(m.completion_tokens)
        }
      )
      |> Repo.one()

    prompt_total = totals[:prompt] || 0
    completion_total = totals[:completion] || 0

    metadata = conversation.metadata || %{}
    token_usage = Map.get(metadata, "token_usage", %{})
    today_usage = Map.get(token_usage, today_str, %{})

    updated_today_usage =
      Map.put(today_usage, model, %{
        "prompt_tokens" => prompt_total,
        "completion_tokens" => completion_total,
        "total_tokens" => prompt_total + completion_total
      })

    updated_metadata =
      metadata
      |> Map.put("token_usage", Map.put(token_usage, today_str, updated_today_usage))

    conversation
    |> Conversation.changeset(%{metadata: updated_metadata})
    |> Repo.update()

    :ok
  rescue
    e ->
      Logger.error(
        "[TokenUsageAggregator] Failed for conversation #{conversation_id}: #{Exception.message(e)}"
      )

      {:error, Exception.message(e)}
  end
end
