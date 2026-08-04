defmodule Zaq.Engine.IncomingAttachments do
  @moduledoc """
  Stores a message's attachments and describes them in the text the agent reads.

  An attachment arrives from a channel as an unmaterialized record pointing at the provider
  that holds the bytes. That reference is short-lived and only reachable from the channels
  node, so this module hands it straight back to channels to be written onto an ingestion
  volume, and keeps the durable record that comes back.

  The stored record is still unmaterialized — now backed by a `documents.id`. The agent
  fetches it only if it decides to, through the same `download_document` tool it already
  uses for any other document, which is why each attachment is also announced as a line of
  text: without a handle in the prompt the model has no way to ask for the file.

  Storage failures never cost the message. The caption still reaches the agent; only the
  attachment line says the file is unavailable.
  """

  require Logger

  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc """
  Persists every attachment on the message and appends a handle line per attachment.

  Returns the message unchanged when it carries no attachments.
  """
  @spec store(Incoming.t(), keyword()) :: Incoming.t()
  def store(%Incoming{} = incoming, opts \\ []) do
    case Incoming.attachment_records(incoming) do
      [] -> incoming
      records -> store_records(incoming, records, opts)
    end
  end

  defp store_records(%Incoming{} = incoming, records, opts) do
    results = Enum.map(records, &persist(&1, incoming, opts))

    incoming
    |> Incoming.put_attachment_records(Enum.map(results, &elem(&1, 1)))
    |> put_content(Enum.map(results, &describe/1))
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
        {:ok, stored}

      other ->
        Logger.warning(
          "[IncomingAttachments] Failed to store attachment " <>
            "provider=#{incoming.provider} name=#{inspect(record.name)} " <>
            "reason=#{inspect(other)}"
        )

        {:error, record}
    end
  end

  # The model can only act on what the text tells it, so a stored attachment carries the two
  # arguments `download_document` needs and a failed one says plainly that it cannot be read.
  defp describe({:ok, %Record{} = record}) do
    "[attachment: #{label(record)}, provider: \"disk\", document_id: \"#{record.id}\"]"
  end

  defp describe({:error, %Record{} = record}) do
    "[attachment: #{label(record)} — could not be stored and cannot be opened]"
  end

  defp label(%Record{name: name, mime_type: mime_type}) do
    case {name, mime_type} do
      {name, nil} when is_binary(name) -> name
      {name, mime} when is_binary(name) -> "#{name} (#{mime})"
      {_, mime} when is_binary(mime) -> "unnamed (#{mime})"
      _ -> "unnamed"
    end
  end

  defp put_content(%Incoming{content: content} = incoming, lines) do
    caption = if is_binary(content), do: String.trim(content), else: ""
    announced = Enum.join(lines, "\n")

    %{incoming | content: join_caption(caption, announced)}
  end

  defp join_caption("", announced), do: announced
  defp join_caption(caption, announced), do: caption <> "\n\n" <> announced
end
