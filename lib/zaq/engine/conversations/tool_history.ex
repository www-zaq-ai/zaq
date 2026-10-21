defmodule Zaq.Engine.Conversations.ToolHistory do
  @moduledoc """
  Internal tool-evidence presentation for messages already authorized by a reader.

  Uses the persisted public-answer relationship, never a reservation or a tool
  name, to resolve execution evidence. Private evidence remains in its existing
  storage. Public display traces contain only allowlisted tool steps; an internal
  full projection retains all evidence for an already-authorized privileged reader.
  This module grants no read permission. Callers must authorize the exact message
  scope and projection before calling it; client flags are not authorization.
  """

  import Ecto.Query

  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.Conversations.{Conversation, ExecutionRecord, Message, TranscriptMessage}
  alias Zaq.Repo

  @doc "Shared exact-answer lookup for already-authorized public or privileged readers."
  def answer_roots_query(ids) do
    from e in ExecutionRecord,
      where: e.public_answer_message_id in ^ids and is_nil(e.root_execution_id)
  end

  @doc "Checks the existing execution input/answer ownership relationship, not viewer permission."
  def valid_execution_owner?(execution, message) do
    [message.id]
    |> owned_answer_roots_query()
    |> where([e], e.id == ^execution.id)
    |> Repo.exists?()
  end

  @doc "Attaches authorized evidence in the existing trace field with one batched query."
  def present(messages, projection \\ :public)

  def present([], _projection), do: []

  def present(messages, projection) do
    ids = Enum.filter(messages, &(&1.role == "assistant")) |> Enum.map(& &1.id)

    evidence =
      ids
      |> owned_answer_roots_query()
      |> completed_evidence()

    Enum.map(messages, fn message ->
      trace =
        if message.role == "assistant", do: Map.get(evidence, message.id, message.trace), else: []

      %{
        message
        | trace: if(projection == :full, do: trace, else: public_trace(trace)),
          metadata: Map.drop(message.metadata || %{}, [:tool_calls, "tool_calls"])
      }
    end)
  end

  @doc "Enriches an already-authorized canonical page with public facts, never private traces."
  @spec present_canonical([map()], Ecto.UUID.t()) :: [map()]
  def present_canonical([], _transcript_id), do: []

  def present_canonical(messages, transcript_id) do
    ids = for %{role: "assistant", message_id: id} <- messages, do: id

    evidence =
      ids
      |> answer_roots_query()
      |> join(:inner, [e], input in Message, on: input.id == e.user_message_id)
      |> join(:inner, [e], answer in Message, on: answer.id == e.public_answer_message_id)
      |> join(:inner, [_e, input], placement in TranscriptMessage,
        on: placement.message_id == input.id and placement.transcript_id == ^transcript_id
      )
      |> join(:inner, [_e, _input, answer], placement in TranscriptMessage,
        on: placement.message_id == answer.id and placement.transcript_id == ^transcript_id
      )
      |> join(:left, [_e, input], conversation in Conversation,
        on: conversation.id == input.conversation_id
      )
      |> where([_e, input, answer], input.role == "user" and answer.role == "assistant")
      |> where(
        [e, input, answer, _input_placement, _answer_placement, conversation],
        is_nil(input.conversation_id) or
          (answer.conversation_id == input.conversation_id and
             conversation.person_id == e.person_id)
      )
      |> completed_evidence()

    Enum.map(messages, fn message ->
      trace =
        if message.role == "assistant",
          do: Map.get(evidence, message.message_id, Map.get(message, :trace, [])),
          else: []

      message |> Map.delete(:trace) |> Map.put(:tool_steps, public_trace(trace))
    end)
  end

  defp completed_evidence(query) do
    query
    |> where([e], e.status == "completed")
    |> select([e], {e.public_answer_message_id, e.trace_entries})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Projects only normalized, identifiable facts; legacy event IDs never become invocation IDs."
  def public_trace(trace), do: ToolStep.from_trace(trace)

  defp owned_answer_roots_query(ids) do
    ids
    |> answer_roots_query()
    |> join(:inner, [e], input in Message, on: input.id == e.user_message_id)
    |> join(:inner, [_e, input], conversation in Conversation,
      on: conversation.id == input.conversation_id
    )
    |> join(:inner, [e], answer in Message, on: answer.id == e.public_answer_message_id)
    |> where(
      [e, input, conversation, answer],
      input.role == "user" and answer.role == "assistant" and
        answer.conversation_id == input.conversation_id and conversation.person_id == e.person_id
    )
  end
end
