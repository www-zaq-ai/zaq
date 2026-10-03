defmodule Zaq.Channels.HistoryDelivery do
  @moduledoc """
  Associates confirmed deliveries through the Engine history boundary.

  Bridges supply normalized receipt evidence. Transport success and history
  persistence are separate results: a failed association must never encourage a
  caller to resend an already accepted message.
  """

  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Records a confirmed delivery when its original history scope is available."
  def capture(
        {:ok, %{confirmation: :confirmed} = receipt},
        %Outgoing{routing_context: %{channel_config_id: id, history_kind: kind}} = outgoing,
        opts
      )
      when is_integer(id) and id > 0 and kind in [:direct, :channel, :replicated] do
    metadata = outgoing.metadata || %{}

    request = %{
      confirmation: :confirmed,
      provider: to_string(outgoing.provider),
      channel_config_id: id,
      kind: kind,
      channel_id: delivery_channel_id(kind, outgoing, receipt),
      conversation_id:
        Map.get(outgoing.routing_context, :conversation_id) || receipt[:history_conversation_id],
      user_message_id: metadata[:user_message_id],
      assistant_message_id: metadata[:assistant_message_id],
      audience: receipt[:history_audience],
      source_scope:
        Map.get(receipt, :history_source_scope, Map.get(outgoing.routing_context, :source_scope)),
      message_id: receipt[:message_id],
      content: outgoing.body
    }

    if kind == :replicated or
         (is_binary(request.user_message_id) and is_binary(request.assistant_message_id)) do
      router = Keyword.get(opts, :history_node_router, NodeRouter)
      event = Event.new(request, :engine, opts: [action: :capture_delivered_history])
      {:ok, Map.merge(receipt, association_status(router, event))}
    else
      {:ok, receipt}
    end
  end

  def capture(response, _outgoing, _opts), do: response

  defp delivery_channel_id(:replicated, _outgoing, %{history_audience: %{recipients: [first | _]}}),
       do: first

  defp delivery_channel_id(_, outgoing, _receipt), do: outgoing.channel_id

  defp association_status(router, event) do
    case router.dispatch(event) do
      %Event{response: {:ok, _}} -> %{history_capture: :stored}
      %Event{response: {:error, reason}} -> unavailable(reason)
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
