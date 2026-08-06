defmodule Zaq.Agent.Tools.Messages.DownloadAttachment do
  @moduledoc """
  ReAct tool: reads a file the sender attached to the message being answered.

  An attachment is not a data source document. No provider ever issued it an id, nothing
  lists it, and its bytes sit behind the channel that received it — so there is no provider
  to name and no id to look up. The record travels on the `%Incoming{}` in `tool_context`
  already carrying the `materializing_event` that fetches the bytes, and this tool dispatches
  exactly that.

  Readability is judged twice. What the channel declared settles the cheap refusal, before
  any bytes move; the fetched record's own type — read from the bytes, since providers like
  Telegram declare none — settles the real one.

  Whether a copy is kept is the channel's business, not the model's: the record's own
  materializing event names the channel it came from, and the channels node answers where —
  if anywhere — files from that channel belong. Looked up here rather than stamped when the
  message arrived, so a change in BO takes effect on the next read rather than the next
  message.
  """

  use Zaq.Engine.Workflows.Action,
    name: "download_attachment",
    output_schema: [
      record: [type: :any, required: false, doc: "Normalized record for the attachment"]
    ],
    description: """
    Read a file the person attached to the message you are answering.

    When a message announces an attachment with an attachment_id, call this tool with that
    id to read it — an image fetched this way comes back as an image you can actually see,
    not as text. This is the only way to open an attachment; it is not a data source
    document and download_document cannot reach it.
    """,
    schema: [
      attachment_id: [
        type: :string,
        required: true,
        doc: "Identifier of the attachment, as announced with the message"
      ]
    ]

  require Logger

  alias Zaq.Agent.Tools.Helpers.ChannelTool
  alias Zaq.Agent.Tools.MediaModality
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.Utils.Map, as: MapUtils

  @error_prefix "Attachment download failed"

  @impl Jido.Action
  def run(%{attachment_id: attachment_id}, context) do
    case find(context, attachment_id) do
      %Record{materializing_event: nil} = record ->
        {:error, "#{@error_prefix}: #{label(record)} cannot be fetched from its channel"}

      %Record{} = record ->
        fetch(record, context, modalities(context))

      nil ->
        {:error, "#{@error_prefix}: no attachment #{inspect(attachment_id)} on this message"}
    end
  end

  defp find(context, attachment_id) do
    case Map.get(context, :incoming) do
      %Incoming{} = incoming -> Incoming.attachment_record(incoming, attachment_id)
      _other -> nil
    end
  end

  defp fetch(%Record{} = record, context, modalities) do
    if MediaModality.readable?(record.mime_type, modalities) do
      with {:ok, materialized} <-
             ChannelTool.materialize(%{record: record}, context, @error_prefix) do
        {:ok,
         materialized
         |> keep_name(record)
         |> keep_copy(channel_of(record), context)
         |> MediaModality.deliver(modalities)}
      end
    else
      {:ok, %{refused: MediaModality.refusal(record.name, record.mime_type)}}
    end
  end

  # ── keeping a copy ──────────────────────────────────────────────────────────

  # The channel the file arrived on, taken off the event that fetches it — the same value the
  # channels node looks its configuration up by.
  defp channel_of(%Record{materializing_event: %Event{request: %{provider: provider}}})
       when is_binary(provider),
       do: provider

  defp channel_of(%Record{}), do: nil

  defp keep_copy(%{record: %Record{} = fetched} = materialized, channel, context)
       when is_binary(channel) do
    case destination(channel, context) do
      %{provider: provider, path: path} ->
        %{materialized | record: store(fetched, provider, path, context)}

      _nothing ->
        materialized
    end
  end

  defp keep_copy(materialized, _channel, _context), do: materialized

  defp destination(channel, context) do
    node_router = Map.get(context, :node_router, Zaq.NodeRouter)

    %{provider: channel}
    |> Event.new(:channels, opts: [action: :attachment_destination])
    |> node_router.dispatch()
    |> Map.fetch!(:response)
    |> case do
      {:ok, %{destination: destination}} -> destination
      _other -> nil
    end
  end

  # A failed write must not cost the read: the model asked to see the file, and keeping a
  # copy is an operator's concern it cannot act on. So the record travels either way and the
  # failure goes to the log.
  defp store(%Record{} = fetched, provider, path, context) do
    params = %{
      "name" => fetched.name,
      "path" => path,
      "content" => fetched.content,
      "encoding" => MapUtils.present_value(fetched.attributes, "encoding")
    }

    request = ChannelTool.wrap_request(params, provider)

    case ChannelTool.dispatch(:data_source_create_file, request, context, @error_prefix) do
      {:ok, %{record: %Record{id: id}}} ->
        annotate(fetched, "stored_document_id", to_string(id))

      other ->
        Logger.warning(
          "[DownloadAttachment] Could not keep a copy of #{inspect(fetched.name)} " <>
            "at #{inspect(path)}: #{inspect(other)}"
        )

        fetched
    end
  end

  defp annotate(%Record{} = record, key, value),
    do: %{record | attributes: Map.put(record.attributes || %{}, key, value)}

  # Materializing answers with the provider's own record, which knows the bytes but not what
  # the file was called — that only ever existed on the inbound one.
  defp keep_name(%{record: %Record{name: nil} = fetched} = materialized, %Record{name: name}),
    do: %{materialized | record: %{fetched | name: name}}

  defp keep_name(materialized, _record), do: materialized

  defp label(%Record{name: name}), do: name || "the attachment"

  defp modalities(context), do: Map.get(context, :input_modalities, [])
end
