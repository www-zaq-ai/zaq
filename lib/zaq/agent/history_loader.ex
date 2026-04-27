defmodule Zaq.Agent.HistoryLoader do
  @moduledoc """
  Loads recent conversation history from the DB and converts it to a
  `Jido.AI.Context` struct for injection into a cold-started agent process.

  This module is the only place that performs DB→Jido.AI.Context conversion.
  It is completely independent of `Zaq.Agent.History`, which serves the
  non-Jido retrieval and BO chat paths.
  """

  import Ecto.Query

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.TokenEstimator
  alias Zaq.Engine.Conversations.{Conversation, Message}
  alias Zaq.Repo

  @default_max_tokens 5_000
  @max_db_fetch 500

  @doc """
  Loads the most recent messages for the given `person_id` + `channel_type`
  pair, accumulates them up to `max_tokens`, and returns a `Jido.AI.Context`.

  Returns an empty context immediately when `person_id` is `nil`.

  ## Options

    * `:max_tokens` — token budget (default: #{@default_max_tokens})
  """
  @spec load(integer() | nil, String.t() | nil, keyword()) :: AIContext.t()
  def load(person_id, channel_type, opts \\ [])
  def load(nil, _channel_type, _opts), do: AIContext.new()
  def load(_person_id, nil, _opts), do: AIContext.new()

  def load(person_id, channel_type, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    messages = fetch_recent_messages(person_id, channel_type)

    messages
    |> accumulate_within_budget(max_tokens)
    |> build_context()
  end

  defp fetch_recent_messages(person_id, channel_type) do
    conv_ids =
      from(c in Conversation,
        where: c.person_id == ^person_id and c.channel_type == ^channel_type,
        select: c.id
      )

    from(m in Message,
      where: m.conversation_id in subquery(conv_ids),
      order_by: [desc: m.inserted_at],
      limit: @max_db_fetch,
      select: %{role: m.role, content: m.content}
    )
    |> Repo.all()
  end

  defp accumulate_within_budget(messages, max_tokens) do
    Enum.reduce_while(messages, {[], 0}, fn msg, {acc, total} ->
      tokens = TokenEstimator.estimate(msg.content || "")
      new_total = total + tokens

      if new_total > max_tokens do
        {:halt, {acc, total}}
      else
        {:cont, {[msg | acc], new_total}}
      end
    end)
    |> elem(0)
  end

  defp build_context(messages) do
    Enum.reduce(messages, AIContext.new(), fn
      %{role: "user", content: content}, ctx ->
        AIContext.append_user(ctx, content || "")

      %{role: "assistant", content: content}, ctx ->
        AIContext.append_assistant(ctx, content || "")

      _other, ctx ->
        ctx
    end)
  end
end
