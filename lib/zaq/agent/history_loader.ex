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
  alias Zaq.Utils.DateUtils

  @default_max_tokens 5_000
  @max_db_fetch 500

  @doc """
  Selects and loads the appropriate history context from a spawn opts map.

  Routes to `load_for_conversation/2` when `:conversation_id` is present,
  otherwise falls back to `load/3` using `:person_id` + `:channel_type`.

  ## Options

    * `:max_tokens` — token budget (default: #{@default_max_tokens})
  """
  @spec load_context(map(), keyword()) :: AIContext.t()
  def load_context(spawn_opts, opts \\ []) do
    case Map.get(spawn_opts, :conversation_id) do
      id when is_binary(id) and id != "" ->
        load_for_conversation(id, opts)

      _ ->
        load(Map.get(spawn_opts, :person_id), Map.get(spawn_opts, :channel_type), opts)
    end
  end

  @doc """
  Loads the most recent messages for the given `conversation_id`, accumulates
  them up to `max_tokens`, and returns a `Jido.AI.Context`.

  Returns an empty context immediately when `conversation_id` is `nil` or `""`.

  ## Options

    * `:max_tokens` — token budget (default: #{@default_max_tokens})
  """
  @spec load_for_conversation(String.t() | nil, keyword()) :: AIContext.t()
  def load_for_conversation(conversation_id, opts \\ [])
  def load_for_conversation(nil, _opts), do: AIContext.new()
  def load_for_conversation("", _opts), do: AIContext.new()

  def load_for_conversation(conversation_id, opts) do
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)

    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      order_by: [desc: m.inserted_at],
      limit: @max_db_fetch,
      select: %{role: m.role, content: m.content, inserted_at: m.inserted_at}
    )
    |> Repo.all()
    |> accumulate_within_budget(max_tokens)
    |> build_context()
  end

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
      select: %{role: m.role, content: m.content, inserted_at: m.inserted_at}
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
      %{role: "user", content: content, inserted_at: ts}, ctx ->
        AIContext.append(ctx, %AIContext.Entry{
          role: :user,
          content: "[#{DateUtils.format_ts(ts)}] #{content || ""}",
          timestamp: ts
        })

      %{role: "assistant", content: content, inserted_at: ts}, ctx ->
        AIContext.append(ctx, %AIContext.Entry{
          role: :assistant,
          content: content || "",
          timestamp: ts
        })

      _other, ctx ->
        ctx
    end)
  end

end
