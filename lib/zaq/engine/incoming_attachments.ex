defmodule Zaq.Engine.IncomingAttachments do
  @moduledoc """
  Stores a message's attachments and describes them in the text the agent reads.

  An attachment arrives from a channel as an unmaterialized record pointing at the provider
  that holds the bytes. That reference is short-lived and only reachable from the channels
  node, so this module hands it straight back to channels to be written onto an ingestion
  volume, and keeps the durable record that comes back.

  The stored record is still unmaterialized — now backed by a `documents.id`. The agent
  fetches it only if it decides to, through the same `download_document` tool it already
  uses for any other document.

  Nothing here touches `content`: what the sender typed stays exactly that, and the text
  describing the attachments is derived from the records by
  `Zaq.Engine.Messages.Incoming.attachment_notice/1` — application context, carried as a
  `system` message rather than put in the person's mouth.

  Storage failures never cost the message. A record that could not be stored is marked
  `attributes["storage"] = "failed"` and still travels, so the agent is told the file exists
  but cannot be opened.
  """

  require Logger

  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc """
  Persists every attachment on the message, swapping each record for the stored one.

  `content` is left untouched — the text describing the attachments is derived from the
  records later. Returns the message unchanged when it carries no attachments.
  """
  @spec store(Incoming.t(), keyword()) :: Incoming.t()
  def store(%Incoming{} = incoming, opts \\ []) do
    case Incoming.attachment_records(incoming) do
      [] -> incoming
      records -> store_records(incoming, records, opts)
    end
  end

  defp store_records(%Incoming{} = incoming, records, opts) do
    stored = Enum.map(records, &persist(&1, incoming, opts))

    Incoming.put_attachment_records(incoming, stored)
  end

  defp persist(%Record{} = record, %Incoming{} = incoming, opts) do
    node_router = Keyword.get(opts, :node_router, NodeRouter)

    request = %{
      record: record,
      person_id: Incoming.person_id(incoming),
      person_name: Incoming.person_name(incoming),
      provider: incoming.provider,
      author_id: incoming.author_id,
      message_id: incoming.message_id,
      node_router: node_router
    }

    case request
         |> Event.new(:channels, opts: [action: :persist_inbound_attachment])
         |> node_router.dispatch()
         |> Map.fetch!(:response) do
      {:ok, %{record: %Record{} = stored}} ->
        stored

      other ->
        Logger.warning(
          "[IncomingAttachments] Failed to store attachment " <>
            "provider=#{incoming.provider} name=#{inspect(record.name)} " <>
            "reason=#{inspect(other)}"
        )

        mark_failed(record)
    end
  end

  # The failure travels on the record rather than in a message built here, so whoever
  # describes the attachments later can say it cannot be opened without needing to know how
  # the storage attempt went.
  defp mark_failed(%Record{} = record) do
    %{record | attributes: Map.put(record.attributes || %{}, "storage", "failed")}
  end
end
