defmodule Zaq.Agent.Tools.Messages.DownloadAttachment do
  @moduledoc """
  ReAct tool: lists and reads the files the sender attached to the message being answered.

  An attachment is not a data source document. No provider ever issued it an id, nothing
  lists it, and its bytes sit behind the channel that received it — so there is no provider
  to name and no id to look up. The record travels on the `%Incoming{}` in `tool_context`
  already carrying the `materializing_event` that fetches the bytes, and this tool dispatches
  exactly that.

  Called without an id it lists instead of fetching. Nothing else tells the model what
  arrived on a message, so the tool has to answer that itself — the alternative is announcing
  attachments in the prompt, which puts an instruction where only the sender's words belong.
  Listing moves no bytes and keeps no copy.

  Readability is judged twice. What the channel declared settles the cheap refusal, before
  any bytes move; the fetched record's own type — read from the bytes, since providers like
  Telegram declare none — settles the real one.

  Reading moves bytes to the caller and keeps no copy. Retaining what an agent looked at is
  the trace's concern, not this tool's.
  """

  use Zaq.Engine.Workflows.Action,
    name: "download_attachment",
    output_schema: [
      record: [type: :any, required: false, doc: "Normalized record for the attachment"],
      attachments: [type: :any, required: false, doc: "One entry per file on the message"]
    ],
    description: """
    List and read the files the person attached to the message you are answering.

    Call this with no arguments first, before answering. You cannot see attachments any
    other way: a message carrying a photo or a document looks exactly like one carrying
    none, and nothing in the conversation will mention it. Listing is cheap — it fetches
    nothing, stores nothing, and returns an empty list when they attached nothing.

    Listing returns one entry per file: attachment_id, name, type and size. Call again with
    an attachment_id to read that file — an image read this way comes back as an image you
    can actually see, not as text.

    Never tell someone you cannot see their attachment, and never ask them whether they sent
    one, until you have listed. This is the only way to open an attachment; it is not a data
    source document and download_document cannot reach it.
    """,
    schema: [
      attachment_id: [
        type: :string,
        required: false,
        doc: "Identifier of the attachment to read. Omit to list what is attached."
      ]
    ]

  alias Zaq.Agent.Tools.Helpers.ChannelTool
  alias Zaq.Agent.Tools.MediaModality
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming

  @error_prefix "Attachment download failed"

  @impl Jido.Action
  def run(%{attachment_id: attachment_id}, context) when is_binary(attachment_id) do
    case find(context, attachment_id) do
      %Record{materializing_event: nil} = record ->
        {:error, "#{@error_prefix}: #{label(record)} cannot be fetched from its channel"}

      %Record{} = record ->
        fetch(record, context, modalities(context))

      nil ->
        {:error, "#{@error_prefix}: no attachment #{inspect(attachment_id)} on this message"}
    end
  end

  def run(_params, context), do: {:ok, %{attachments: listing(context)}}

  # ── listing ─────────────────────────────────────────────────────────────────

  defp listing(context), do: context |> records() |> Enum.map(&entry/1)

  defp records(context) do
    case Map.get(context, :incoming) do
      %Incoming{} = incoming -> Incoming.attachment_records(incoming)
      _other -> []
    end
  end

  # The id is keyed by the parameter name that reads it back, so there is nothing to infer
  # between seeing a file and asking for it. A record with no materializing event says so
  # here rather than costing a call that can only fail.
  defp entry(%Record{} = record) do
    %{
      attachment_id: record.id,
      name: record.name,
      mime_type: record.mime_type,
      size: record.size,
      readable: record.materializing_event != nil
    }
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
         |> MediaModality.deliver(modalities)}
      end
    else
      {:ok, %{refused: MediaModality.refusal(record.name, record.mime_type)}}
    end
  end

  # Materializing answers with the provider's own record, which knows the bytes but not what
  # the file was called — that only ever existed on the inbound one.
  defp keep_name(%{record: %Record{name: nil} = fetched} = materialized, %Record{name: name}),
    do: %{materialized | record: %{fetched | name: name}}

  defp keep_name(materialized, _record), do: materialized

  defp label(%Record{name: name}), do: name || "the attachment"

  defp modalities(context), do: Map.get(context, :input_modalities, [])
end
