defmodule Zaq.Channels.DeliveryConfirmation do
  @moduledoc """
  Reports normalized transport confirmations to Engine without choosing consumer policy.

  Transport success is preserved even if the downstream consumer is unavailable;
  reporting a receipt must never cause the accepted message to be resent.
  """

  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Forwards a confirmed receipt and its original outgoing message to Engine."
  def record({:ok, %{confirmation: :confirmed} = receipt}, outgoing, opts) do
    router = Keyword.get(opts, :delivery_node_router, NodeRouter)

    outgoing = %{
      outgoing
      | metadata: Map.take(outgoing.metadata || %{}, [:user_message_id, :assistant_message_id])
    }

    event =
      Event.new(%{receipt: receipt, outgoing: outgoing}, :engine,
        opts: [action: :record_delivery_confirmation]
      )

    case router.dispatch(event) do
      %Event{response: {:ok, result}} ->
        {:ok, result}

      _ ->
        {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}
    end
  rescue
    _ ->
      {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}
  catch
    :exit, _ ->
      {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}
  end

  def record(response, _outgoing, _opts), do: response
end
