defmodule Zaq.Agent.HistoryLoader do
  @moduledoc """
  Loads recent conversation history from the DB and converts it to a
  `Jido.AI.Context` struct for injection into a cold-started agent process.
  Also converts and merges Engine-authorized canonical projections for request-local
  refresh, without mutating retained runtime context or owning authorization.

  This module is the only place that performs DB→Jido.AI.Context conversion.
  It is completely independent of `Zaq.Agent.History`, which serves the
  non-Jido retrieval and BO chat paths.
  """

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.InputPrompt
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.Message

  @max_db_fetch 500

  @doc "Converts an Engine-authorized canonical projection without querying storage or permissions."
  @spec from_projection([map()], keyword()) :: AIContext.t()
  def from_projection(messages, opts \\ []) do
    Enum.reduce(messages, AIContext.new(), fn message, context ->
      role = if message.role == "assistant", do: :assistant, else: :user
      timestamp = message[:timestamp] || Message.presentation_timestamp(message)

      AIContext.append(context, %AIContext.Entry{
        role: role,
        content: history_content(message, opts),
        timestamp: timestamp && timestamp.value,
        refs: Map.take(message, [:message_id, :transcript_id, :position])
      })
    end)
  end

  @doc "Merges canonical additions into a request-local context, retaining active tool exchanges."
  def merge_projection(%AIContext{} = context, messages, opts \\ []) do
    known = MapSet.new(context.entries, fn entry -> Map.get(entry.refs || %{}, :message_id) end)

    additions =
      messages
      |> Enum.reject(&MapSet.member?(known, &1.message_id))
      |> Enum.uniq_by(& &1.message_id)
      |> from_projection(opts)

    {history, active} =
      context.entries
      |> Enum.reverse()
      |> Enum.split_while(fn entry ->
        entry.role == :system or is_binary(Map.get(entry.refs || %{}, :transcript_id)) or
          Map.get(entry.refs || %{}, :history_completed, false)
      end)

    %{context | entries: Enum.reverse(history ++ Enum.reverse(additions.entries) ++ active)}
  end

  @doc "Binds the completed native answer to its persisted UUID without replacing tool exchanges."
  def bind_completed_answer(context, message_id, content \\ nil)

  def bind_completed_answer(%AIContext{} = context, message_id, content)
      when is_binary(message_id) do
    case context.entries do
      [%AIContext.Entry{role: :assistant} = entry | rest] ->
        entry = %{entry | refs: Map.put(entry.refs || %{}, :message_id, message_id)}
        entry = if is_binary(content), do: %{entry | content: content}, else: entry
        %{context | entries: [entry | rest]}

      _ ->
        context
    end
  end

  def bind_completed_answer(context, _message_id, _content), do: context

  @doc "Merges the completed request and marks retained exchanges as history for the next turn."
  def complete_projection(%AIContext{} = context, messages, opts \\ []) do
    context = merge_projection(context, messages, opts)

    %{
      context
      | entries:
          Enum.map(context.entries, fn entry ->
            %{entry | refs: Map.put(entry.refs || %{}, :history_completed, true)}
          end)
    }
  end

  @doc """
  Selects and loads the appropriate history context from a spawn opts map.

  Routes to `load_for_conversation/2` when `:conversation_id` is present,
  otherwise falls back to `load/3` using `:person_id` + `:channel_type`.

  Loads at most #{@max_db_fetch} rows. Model context-window enforcement happens
  later when projecting a concrete outbound LLM request.
  """
  @spec load_context(map(), keyword()) :: AIContext.t()
  def load_context(spawn_opts, opts \\ []) do
    conversation_id = Map.get(spawn_opts, :conversation_id)

    if is_binary(conversation_id) and conversation_id != "" do
      load_for_conversation(conversation_id, opts)
    else
      load(Map.get(spawn_opts, :person_id), Map.get(spawn_opts, :channel_type), opts)
    end
  end

  @doc """
  Loads the most recent messages for the given `conversation_id` and returns a
  `Jido.AI.Context`.

  Returns an empty context immediately when `conversation_id` is `nil` or `""`.
  """
  @spec load_for_conversation(String.t() | nil, keyword()) :: AIContext.t()
  def load_for_conversation(conversation_id, opts \\ [])
  def load_for_conversation(nil, _opts), do: AIContext.new()
  def load_for_conversation("", _opts), do: AIContext.new()

  def load_for_conversation(conversation_id, opts) do
    Conversations.list_agent_history(%{conversation_id: conversation_id})
    |> Enum.reverse()
    |> build_context(opts)
  end

  @doc """
  Loads the most recent messages for the given `person_id` + `channel_type` pair
  and returns a `Jido.AI.Context`.

  Returns an empty context immediately when `person_id` is `nil`.
  """
  @spec load(integer() | nil, String.t() | nil, keyword()) :: AIContext.t()
  def load(person_id, channel_type, opts \\ [])
  def load(nil, _channel_type, _opts), do: AIContext.new()
  def load(_person_id, nil, _opts), do: AIContext.new()

  def load(person_id, channel_type, opts) do
    Conversations.list_agent_history(%{person_id: person_id, channel_type: channel_type})
    |> Enum.reverse()
    |> build_context(opts)
  end

  defp build_context(messages, opts) do
    Enum.reduce(messages, AIContext.new(), fn
      %{role: role} = message, ctx when role in ["user", "assistant"] ->
        AIContext.append(ctx, %AIContext.Entry{
          role: if(role == "assistant", do: :assistant, else: :user),
          content: history_content(message, opts),
          timestamp: message.timestamp && message.timestamp.value
        })

      _other, ctx ->
        ctx
    end)
  end

  defp history_content(message, opts) when is_map(message) do
    attachments =
      case Map.get(message, :attachments) do
        [_ | _] = attachments -> attachments
        _ -> safe_attachments(Map.get(message, :metadata))
      end

    message
    |> Map.put(:content, Map.get(message, :content) || "")
    |> Map.put(
      :timestamp,
      Map.get(message, :timestamp) || Message.presentation_timestamp(message)
    )
    |> Map.put(:attachments, attachments)
    |> InputPrompt.render_message(opts)
  end

  defp safe_attachments(metadata) when is_map(metadata) do
    metadata
    |> Map.get("attachments", Map.get(metadata, :attachments, []))
    |> case do
      attachments when is_list(attachments) ->
        attachments
        |> Enum.filter(&is_map/1)

      _ ->
        []
    end
  end

  defp safe_attachments(_metadata), do: []
end
