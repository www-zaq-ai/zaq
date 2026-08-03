defmodule Zaq.Agent.Tools.DataSource.DownloadDocument do
  @moduledoc """
  ReAct tool: downloads a document by id from a datasource provider.

  Takes a provider key and a document id, dispatches `download_document` to Channels, and
  passes the answer to `Zaq.Contracts.Record.Materializer`, which returns a record carrying
  content. The number of round trips depends on the provider — an external one answers with
  bytes, `disk` answers with metadata plus the event that fetches them from Ingestion — and
  the materializer resolves either shape, so this tool never branches on it.
  """

  @schema Zoi.object(%{
            provider:
              Zoi.string(
                description:
                  "Datasource provider key. Use the value given to you — for a skill " <>
                    "reference file that is the `provider` on the entry `load_skill` returned."
              ),
            document_id:
              Zoi.string(
                description:
                  "Provider document identifier. For a skill reference file this is the " <>
                    "`id` on the entry `load_skill` returned."
              ),
            document_mime_type:
              Zoi.string(
                description:
                  "Optional source MIME type of the provider document. Used for automatic export type decision."
              )
              |> Zoi.optional(),
            export_mime_type:
              Zoi.string(
                description:
                  "Optional target MIME type to request provider export when supported."
              )
              |> Zoi.optional(),
            config_id:
              Zoi.string(description: "Optional scoped datasource config id.") |> Zoi.optional()
          })

  # A plain map, not the `%Record{}` struct: Zoi's map type rejects structs, `Zoi.any/1`
  # cannot be encoded to JSON Schema at all, and `Zoi.struct/3` would have to mirror every
  # field of the struct and drop any it did not declare. `Record.to_map/1` projects through
  # the record's own public-field list, so `raw` and `materializing_event` cannot leak here
  # any more than they can through its JSON encoder.
  @output_schema Zoi.object(%{
                   record:
                     Zoi.map(
                       description:
                         "Normalized record including the document's content, plus whatever " <>
                           "metadata the provider supplied (name, mime_type, size)."
                     )
                 })

  use Zaq.Engine.Workflows.Action,
    name: "download_document",
    description: """
    Download a document by id from a specific datasource provider.
    Returns a normalized record including document content.
    """,
    schema: @schema,
    output_schema: @output_schema

  alias Jido.Action.Tool
  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Agent.Tools.Error
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Materializer
  alias Zaq.NodeRouter

  # Tool calls arrive from the model with string keys, and a Zoi object keyed by atoms
  # rejects those outright ("is required, at provider"). Converting first is what makes the
  # schema usable from an LLM at all.
  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params) do
    {:ok, Tool.convert_params_using_schema(params, schema())}
  end

  def on_before_validate_params(params), do: {:ok, params}

  @error_prefix "Data source document download failed"

  @impl Jido.Action

  def run(%{provider: provider, document_id: document_id} = params, context) do
    request =
      %{"file_id" => document_id}
      |> DataSourceTool.merge_optional(params, [
        :document_mime_type,
        :export_mime_type,
        :config_id
      ])
      |> DataSourceTool.wrap_request(provider)

    DataSourceTool.dispatch(
      :data_source_download_document,
      request,
      context,
      @error_prefix,
      &finish(&1, document_id, context)
    )
  end

  # What comes back depends on the provider, and the tool does not care which: an external
  # one answers with bytes, `disk` answers with metadata and the event that fetches them
  # from Ingestion. `materialize_response/3` settles either into a record with content.
  #
  # The stub carries the only thing the tool knows independently — the id it asked for — so
  # a provider that omits it from its answer still yields an identifiable record.
  defp finish(payload, document_id, context) do
    payload
    |> Materializer.materialize_response(%Record{id: document_id, kind: :file},
      node_router: node_router(context)
    )
    |> to_tool_result()
  end

  defp to_tool_result({:ok, %Record{} = record}), do: {:ok, %{record: Record.to_map(record)}}

  defp to_tool_result({:error, reason}),
    do: {:error, "#{@error_prefix}: #{Error.format(reason)}"}

  defp node_router(context), do: Map.get(context, :node_router, NodeRouter)
end
