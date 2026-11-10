defmodule Zaq.Engine.Conversations.ToolHistory do
  @moduledoc """
  Internal tool-evidence presentation for messages already authorized by a reader.

  Uses the persisted public-answer relationship, never a reservation or a tool
  name, to resolve execution evidence. Private evidence remains in its existing
  storage. Public display traces contain only allowlisted tool steps; an internal
  full projection retains all evidence for an already-authorized privileged reader.
  `AnswerOwnership` owns the persisted relationship queries used by these projections.
  This module grants no read permission. Callers must authorize the exact message
  scope and projection before calling it; client flags are not authorization.
  """

  import Ecto.Query

  alias Zaq.Contracts.ToolStep
  alias Zaq.Engine.Conversations.AnswerOwnership
  alias Zaq.Repo

  @doc "Attaches authorized evidence in the existing trace field with one batched query."
  def present(messages, projection \\ :public)

  def present([], _projection), do: []

  def present(messages, projection) do
    ids = Enum.filter(messages, &(&1.role == "assistant")) |> Enum.map(& &1.id)

    evidence =
      AnswerOwnership.owned_root_executions_query()
      |> where([answer: answer], answer.id in ^ids)
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
      AnswerOwnership.canonical_root_executions_query(transcript_id)
      |> where([answer: answer], answer.id in ^ids)
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
    |> where([execution: execution], execution.status == "completed")
    |> select(
      [execution: execution],
      {execution.public_answer_message_id, execution.trace_entries}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "Projects only normalized, identifiable facts; legacy event IDs never become invocation IDs."
  def public_trace(trace), do: ToolStep.from_trace(trace)
end
