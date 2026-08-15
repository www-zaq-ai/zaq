defmodule Zaq.Agent.Tools.DataSource.DownloadDocument do
  @moduledoc """
  ReAct tool: downloads datasource document content.

  Prefer passing a metadata `%Zaq.Contracts.Record{}` returned by browse/list/search/get when it
  has a `materializing_event`; that event is the provider-specific download route and preserves
  the record metadata that selected the document. The legacy `provider` + `document_id` path is
  still supported for callers that only have an identifier.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  @schema Zoi.object(
            %{
              record:
                Zoi.map(description: "Metadata record with a materializing event.")
                |> Zoi.optional(),
              provider:
                Zoi.string(description: "Datasource provider key.")
                |> Zoi.optional(),
              document_id:
                Zoi.string(description: "Provider document identifier.")
                |> Zoi.optional(),
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
                Zoi.string(description: "Optional scoped datasource config id.")
                |> Zoi.optional()
            },
            unrecognized_keys: :preserve
          )
          |> Zoi.refine({__MODULE__, :validate_input_mode, []})

  use Zaq.Engine.Workflows.Action,
    name: "download_document",
    output_schema: [
      record: [type: :any, required: false, doc: "Normalized record including document content"]
    ],
    description: """
    Download datasource document content.

    Pass either a metadata record with a materializing event, or a provider plus document_id.
    The record path is preferred when the document came from a datasource browse/list/search/get
    result, because the event already carries the correct routed download request.

    Returns a normalized record including document content.
    """,
    schema: @schema

  alias Jido.Action.Tool
  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Contracts.RecordMaterializer

  @impl Jido.Action

  def on_before_validate_params(params) when is_map(params),
    do: {:ok, Tool.convert_params_using_schema(params, schema())}

  def on_before_validate_params(params), do: {:ok, params}

  @doc false
  def validate_input_mode(params, _opts \\ [])

  def validate_input_mode(params, _opts) when is_map(params) do
    has_record? = present?(Map.get(params, :record) || Map.get(params, "record"))
    has_provider? = present?(Map.get(params, :provider) || Map.get(params, "provider"))
    has_document_id? = present?(Map.get(params, :document_id) || Map.get(params, "document_id"))

    cond do
      has_record? ->
        :ok

      has_provider? and has_document_id? ->
        :ok

      true ->
        {:error, "provide either record or provider with document_id"}
    end
  end

  def validate_input_mode(_params, _opts),
    do: {:error, "download_document input must be an object"}

  @impl Jido.Action

  def run(%{record: record}, context) do
    RecordMaterializer.materialize(
      %{record: record},
      context,
      "Data source document download failed"
    )
  end

  def run(%{provider: provider, document_id: document_id} = params, context) do
    request =
      %{"file_id" => document_id}
      |> DataSourceTool.merge_optional(params, [
        :document_mime_type,
        :export_mime_type,
        :config_id
      ])
      |> DataSourceTool.wrap_request(provider)

    error_prefix = "Data source document download failed"

    DataSourceTool.dispatch(
      :data_source_download_document,
      request,
      context,
      error_prefix,
      &RecordMaterializer.materialize(&1, context, error_prefix)
    )
  end

  def run(_params, _context), do: {:error, "Provide either record or provider with document_id"}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true
end
