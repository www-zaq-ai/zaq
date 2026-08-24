defmodule Zaq.Agent.Tools.DataSource.DownloadDocument do
  @moduledoc """
  ReAct tool: materializes Record content.

  Pass either a `materialization_handle` returned by a Record, or a `provider` +
  `document_id` pair. The provider pair may include `config_id` to select an explicit
  data-source configuration.

  Delegates to Channels through `NodeRouter.dispatch/1`.
  """

  @schema Zoi.object(
            %{
              materialization_handle:
                Zaq.Materialization.Handle.zoi_type(
                  description:
                    "Signed materialization handle returned by any supported unmaterialized Record, including data-source documents and communication-channel attachments."
                )
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

  @output_schema Zoi.object(
                   %{
                     record:
                       Zaq.Contracts.Record.zoi_type(
                         description: "Normalized record including document content"
                       )
                       |> Zoi.optional()
                   },
                   unrecognized_keys: :preserve
                 )

  use Zaq.Engine.Workflows.Action,
    name: "download_document",
    output_schema: @output_schema,
    description: """
    Materialize a record to retrieve its full content.

    Pass either a materialization_handle, or a data-source provider plus document_id.
    Handles can materialize any supported Record, including communication-channel attachments.
    Include config_id with provider/document_id when a specific data-source config is required.

    Returns the normalized record including its materialized content.
    """,
    schema: @schema

  alias Jido.Action.Tool
  alias Zaq.Agent.Tools.DataSourceTool
  alias Zaq.Channels.Materializers.DataSourceDocument
  alias Zaq.Helpers
  alias Zaq.Materialization

  @impl Jido.Action

  def on_before_validate_params(params) when is_map(params),
    do: {:ok, Tool.convert_params_using_schema(params, schema())}

  def on_before_validate_params(params), do: {:ok, params}

  @doc false
  def validate_input_mode(params, _opts \\ [])

  def validate_input_mode(params, _opts) when is_map(params) do
    has_handle? =
      not Helpers.blank?(
        Map.get(params, :materialization_handle) || Map.get(params, "materialization_handle")
      )

    has_provider? = not Helpers.blank?(Map.get(params, :provider) || Map.get(params, "provider"))

    has_document_id? =
      not Helpers.blank?(Map.get(params, :document_id) || Map.get(params, "document_id"))

    has_provider_mode? = has_provider? and has_document_id?

    validate_input_mode_flags(has_handle?, has_provider_mode?)
  end

  def validate_input_mode(_params, _opts),
    do: {:error, "download_document input must be an object"}

  defp validate_input_mode_flags(true, false), do: :ok
  defp validate_input_mode_flags(false, true), do: :ok

  defp validate_input_mode_flags(_has_handle?, _has_provider_mode?),
    do: {:error, "provide either materialization_handle or provider with document_id"}

  @impl Jido.Action

  def run(%{materialization_handle: handle} = params, context) when is_binary(handle) do
    Materialization.materialize(
      handle,
      context,
      "Record materialization failed",
      materialization_options(params)
    )
  end

  def run(%{provider: provider, document_id: document_id} = params, context) do
    error_prefix = "Data source document download failed"
    attrs = optional_attrs(params)

    with {:ok, handle} <- DataSourceDocument.issue(provider, document_id, attrs),
         {:ok, payload} <-
           Materialization.materialize(
             handle,
             context,
             error_prefix,
             materialization_options(params)
           ) do
      {:ok, payload}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "#{error_prefix}: #{inspect(reason)}"}
    end
  end

  def run(_params, _context),
    do: {:error, "Provide either materialization_handle or provider with document_id"}

  defp optional_attrs(params) do
    %{}
    |> DataSourceTool.merge_optional(params, [:document_mime_type, :config_id])
    |> Map.reject(fn {_key, value} -> Helpers.blank?(value) end)
  end

  defp materialization_options(params) do
    %{}
    |> DataSourceTool.merge_optional(params, [:export_mime_type])
    |> Map.reject(fn {_key, value} -> Helpers.blank?(value) end)
  end
end
