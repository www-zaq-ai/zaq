defmodule Zaq.Channels.DeliveryConfirmation do
  @moduledoc """
  Reports normalized transport confirmations to Engine without choosing consumer policy.

  Transport success is preserved even if the downstream consumer is unavailable;
  reporting a receipt must never cause the accepted message to be resent.
  The confirmation copy clears attachment content while preserving Records and
  their materialization handles, and retains only canonical metadata IDs.
  """

  alias Zaq.Contracts.Record
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Forwards a confirmed receipt and outgoing copy with content-free attachment Records to Engine."
  def record({:ok, %{messages: messages} = report}, outgoing, opts) when is_list(messages) do
    receipts =
      Enum.map(messages, fn receipt ->
        attachments =
          if Map.has_key?(receipt, :delivered_attachment_indices),
            do: outgoing.attachments,
            else: []

        part = %{
          outgoing
          | body: Map.get(receipt, :body, outgoing.body),
            thread_id: receipt[:thread_id],
            attachments: attachments
        }

        {:ok, recorded} = record({:ok, receipt}, part, opts)
        recorded
      end)

    {:ok, report |> Map.delete(:delivered_attachment_indices) |> Map.put(:messages, receipts)}
  end

  def record({:ok, %{confirmation: :confirmed} = receipt}, outgoing, opts) do
    router = Keyword.get(opts, :delivery_node_router, NodeRouter)
    attachments = confirmed_attachment_records(outgoing.attachments, receipt)

    receipt =
      receipt
      |> put_confirmed_attachment_metadata(attachments)
      |> Map.delete(:delivered_attachment_indices)

    outgoing = %{
      outgoing
      | attachments: Enum.map(attachments, &%{&1 | content: nil}),
        metadata:
          Map.take(outgoing.metadata || %{}, [
            :user_message_id,
            :assistant_message_id,
            :persisted_assistant_message_id
          ])
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

  defp put_confirmed_attachment_metadata(
         %{delivered_attachment_indices: _} = receipt,
         attachments
       ) do
    metadata =
      Enum.map(attachments, fn record ->
        record |> Record.attachment_metadata() |> Map.drop(["id", "attributes"])
      end)

    Map.put_new(receipt, :attachments, metadata)
  end

  defp put_confirmed_attachment_metadata(receipt, _attachments), do: receipt

  defp confirmed_attachment_records(attachments, %{delivered_attachment_indices: indices})
       when is_list(indices) do
    attachments
    |> Enum.with_index()
    |> Enum.filter(fn {_record, index} -> index in indices end)
    |> Enum.map(&elem(&1, 0))
  end

  defp confirmed_attachment_records(_attachments, %{delivered_attachment_indices: _}), do: []

  defp confirmed_attachment_records(attachments, _receipt), do: attachments
end
