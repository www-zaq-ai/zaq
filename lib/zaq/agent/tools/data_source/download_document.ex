defmodule Zaq.Agent.Tools.DataSource.DownloadDocument do
  @moduledoc """
  ReAct tool: downloads a document by id from a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`. A bridge that answers with an
  unmaterialized record — `content: nil` plus a `materializing_event` — takes a second hop
  through that event, so the tool returns content whichever way the provider works.
  """

  @schema Zoi.object(%{
            provider: Zoi.string(description: "Datasource provider key"),
            document_id: Zoi.string(description: "Provider document identifier"),
            document_mime_type:
              Zoi.string(
                description:
                  "Optional source MIME type of the provider document. Used for automatic export type decision."
              )
              |> Zoi.optional(),
            export_mime_type:
              Zoi.string(
                description: "Optional target MIME type to request provider export when supported"
              )
              |> Zoi.optional(),
            config_id:
              Zoi.string(description: "Optional scoped datasource config id")
              |> Zoi.optional()
          })

  @output_schema Zoi.object(%{
                   record:
                     Zoi.any(description: "Normalized record including document content")
                     |> Zoi.optional()
                 })

  use Zaq.Engine.Workflows.Action,
    name: "download_document",
    description: """
    Download a document by id from a specific datasource provider.
    Returns a normalized record including document content.

    Files people send on a communication channel are data source documents too: they are
    stored under the "disk" provider as they arrive. When a message announces an attachment
    with a document_id, call this tool with provider="disk" and that id to read it — an
    image fetched this way is returned as an image you can actually see, not as text.
    """,
    schema: @schema,
    output_schema: @output_schema

  alias Zaq.Agent.Tools.Helpers.ChannelTool
  alias Zaq.Agent.Tools.MediaModality
  alias Zaq.Contracts.Record

  @error_prefix "Data source document download failed"

  @impl Jido.Action

  # Refuse before dispatching when the caller already told us the type and this model cannot
  # read it — no point fetching bytes the model can only ignore.
  def run(%{document_mime_type: mime_type} = params, context) when is_binary(mime_type) do
    if MediaModality.readable?(mime_type, modalities(context)) do
      download(params, context)
    else
      {:ok, %{refused: MediaModality.refusal(Map.get(params, :document_id), mime_type)}}
    end
  end

  def run(params, context), do: download(params, context)

  defp download(%{provider: provider, document_id: document_id} = params, context) do
    request =
      %{"file_id" => document_id}
      |> ChannelTool.merge_optional(params, [
        :document_mime_type,
        :export_mime_type,
        :config_id
      ])
      |> ChannelTool.wrap_request(provider)

    ChannelTool.dispatch(
      :data_source_download_document,
      request,
      context,
      @error_prefix,
      &on_downloaded(&1, context)
    )
  end

  # The record's own MIME type is the authority — the caller may have sent none, or guessed
  # wrong — so readability is settled again once the bytes are in hand.
  defp on_downloaded(payload, context) do
    with {:ok, materialized} <- ChannelTool.materialize(payload, context, @error_prefix) do
      {:ok, apply_modality(materialized, modalities(context))}
    end
  end

  # Only a canonical record can be judged: a provider answering with its own map shape has no
  # `mime_type` to read, so it passes through exactly as it did before this check existed.
  defp apply_modality(%{record: %Record{} = record} = materialized, modalities) do
    if MediaModality.readable?(record.mime_type, modalities) do
      MediaModality.put_content_parts(materialized, modalities)
    else
      %{refused: MediaModality.refusal(record.name, record.mime_type)}
    end
  end

  defp apply_modality(materialized, _modalities), do: materialized

  defp modalities(context), do: Map.get(context, :input_modalities, [])
end
