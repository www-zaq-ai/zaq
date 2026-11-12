defmodule Zaq.Engine.Conversations.AnswerOwnership do
  @moduledoc """
  Persisted input, answer and root-execution relationship queries.

  Conversation-backed ownership and canonical transcript eligibility remain
  distinct. Canonical evidence can use conversation-less messages only when both
  are placed in the requested transcript; that does not authorize private reads.
  Raw roots preserve the distinction between missing and invalid evidence.

  These queries grant no reader or actor permission, perform no writes and do not
  choose completion, delivery or trace-presentation policy. Callers add their
  bounded selection and eligibility filters through the named bindings.
  """

  import Ecto.Query

  alias Zaq.Engine.Conversations.{Conversation, ExecutionRecord, Message, TranscriptMessage}

  @doc "Pairs user inputs and assistant answers in the same existing conversation."
  def conversation_pairs_query do
    same_conversation = same_conversation()

    from(answer in Message,
      as: :answer,
      join: input in Message,
      as: :input,
      on: ^same_conversation
    )
    |> with_conversation()
  end

  @doc "Finds raw roots without discarding records whose ownership is invalid."
  def root_executions_query do
    from execution in ExecutionRecord,
      as: :execution,
      where: is_nil(execution.root_execution_id)
  end

  @doc "Resolves exact execution references with matching conversation and Person ownership."
  def owned_root_executions_query do
    same_conversation = same_conversation()
    matching_owner = matching_owner()

    root_executions_query()
    |> with_messages()
    |> with_conversation()
    |> where(^same_conversation)
    |> where(^matching_owner)
  end

  @doc "Requires both transcript placements; conversation-backed rows also require ownership."
  def canonical_root_executions_query(transcript_id) do
    roles = message_roles()
    same_conversation = same_conversation()
    matching_owner = matching_owner()

    eligible =
      dynamic(
        [input: input],
        is_nil(input.conversation_id) or (^same_conversation and ^matching_owner)
      )

    root_executions_query()
    |> with_messages()
    |> join(:inner, [input: input], placement in TranscriptMessage,
      on: placement.message_id == input.id and placement.transcript_id == ^transcript_id
    )
    |> join(:inner, [answer: answer], placement in TranscriptMessage,
      on: placement.message_id == answer.id and placement.transcript_id == ^transcript_id
    )
    |> join(:left, [input: input], conversation in Conversation,
      as: :conversation,
      on: conversation.id == input.conversation_id
    )
    |> where(^roles)
    |> where(^eligible)
  end

  defp with_messages(query) do
    query
    |> join(:inner, [execution: execution], input in Message,
      as: :input,
      on: input.id == execution.user_message_id
    )
    |> join(:inner, [execution: execution], answer in Message,
      as: :answer,
      on: answer.id == execution.public_answer_message_id
    )
  end

  defp with_conversation(query) do
    roles = message_roles()

    query
    |> join(:inner, [input: input], conversation in Conversation,
      as: :conversation,
      on: conversation.id == input.conversation_id
    )
    |> where(^roles)
  end

  defp message_roles,
    do:
      dynamic([input: input, answer: answer], input.role == "user" and answer.role == "assistant")

  defp same_conversation,
    do: dynamic([input: input, answer: answer], answer.conversation_id == input.conversation_id)

  defp matching_owner,
    do:
      dynamic(
        [execution: execution, conversation: conversation],
        conversation.person_id == execution.person_id
      )
end
