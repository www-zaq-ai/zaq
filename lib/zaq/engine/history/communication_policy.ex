defmodule Zaq.Engine.History.CommunicationPolicy do
  @moduledoc """
  Engine-owned interpretation of normalized communication facts for history.

  Channels describes the conversation, never the history strategy or capture
  policy. Unknown facts remain unsupported; provider names and legacy strategy
  hints are not evidence. Existing strategy modules own association and access.
  """

  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  @doc "Selects history kind from a trusted normalized conversation characteristic."
  @spec kind(Incoming.t() | Outgoing.t()) ::
          {:ok, :direct | :channel | :replicated} | {:error, atom()}
  def kind(%{routing_context: %{conversation_type: :one_to_one}}), do: {:ok, :direct}
  def kind(%{routing_context: %{conversation_type: :room}}), do: {:ok, :channel}

  def kind(%{routing_context: %{conversation_type: :recipient_addressed}}),
    do: {:ok, :replicated}

  def kind(_), do: {:error, :unsupported_history_kind}

  @doc "Selects the history title presentation from normalized conversation facts."
  def title_style(%Incoming{routing_context: %{conversation_type: :one_to_one}}), do: :person

  def title_style(%Incoming{routing_context: %{conversation_type: :recipient_addressed}}),
    do: :person_subject

  def title_style(_), do: nil
end
