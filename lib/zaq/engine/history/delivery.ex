defmodule Zaq.Engine.History.Delivery do
  @moduledoc """
  Interprets normalized delivery confirmations using Engine history policy.

  Bridges supply normalized receipt evidence. Transport success and history
  persistence are separate results: a failed association must never encourage a
  caller to resend an already accepted message.
  """

  alias Zaq.Engine.History.CommunicationPolicy
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Engine.Messages.Outgoing

  @doc "Records a confirmed delivery when its original history scope is available."
  def capture(response, outgoing, opts \\ [])

  def capture(
        {:ok, %{confirmation: :confirmed} = receipt},
        %Outgoing{routing_context: %{channel_config_id: id}} = outgoing,
        opts
      )
      when is_integer(id) and id > 0 do
    case CommunicationPolicy.kind(outgoing) do
      {:ok, kind} -> capture_kind(receipt, outgoing, kind, opts)
      {:error, _} -> {:ok, receipt}
    end
  end

  def capture(response, _outgoing, _opts), do: response

  defp capture_kind(receipt, outgoing, kind, _opts) do
    id = outgoing.routing_context.channel_config_id
    metadata = outgoing.metadata || %{}

    request = %{
      confirmation: :confirmed,
      provider: to_string(outgoing.provider),
      channel_config_id: id,
      kind: kind,
      channel_id: delivery_channel_id(kind, outgoing, receipt),
      conversation_id:
        Map.get(outgoing.routing_context, :conversation_id) || receipt[:conversation_id],
      user_message_id: metadata[:user_message_id],
      assistant_message_id: metadata[:assistant_message_id],
      audience: receipt[:audience],
      source_scope:
        Map.get(receipt, :source_scope, Map.get(outgoing.routing_context, :source_scope)),
      message_id: receipt[:message_id],
      content: outgoing.body
    }

    if kind == :replicated or
         (is_binary(request.user_message_id) and is_binary(request.assistant_message_id)) do
      {:ok, Map.merge(receipt, association_status(request))}
    else
      {:ok, receipt}
    end
  end

  defp delivery_channel_id(:replicated, _outgoing, %{audience: %{recipients: [first | _]}}),
    do: first

  defp delivery_channel_id(_, outgoing, _receipt), do: outgoing.channel_id

  defp association_status(request) do
    case HistoryIngress.capture_confirmed(request) do
      {:ok, _} -> %{history_capture: :stored}
      {:error, reason} -> unavailable(reason)
      _ -> unavailable(:invalid_response)
    end
  rescue
    _ -> unavailable(:history_capture_failed)
  catch
    :exit, _ -> unavailable(:history_capture_unavailable)
  end

  defp unavailable(reason) do
    safe =
      if reason in [
           :invalid_delivery_scope,
           :invalid_recipient_evidence,
           :no_linked_recipient,
           :invalid_execution_response,
           :conflicting_delivery_confirmation,
           :source_scope_mismatch,
           :unavailable_history_input,
           :source_conflict
         ], do: reason, else: :history_capture_unavailable

    %{history_capture: :unavailable, history_capture_error: safe}
  end
end
