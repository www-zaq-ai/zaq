defmodule Zaq.Agent.Tools.DataSource.DownloadDocument do
  @moduledoc """
  ReAct tool: materializes Record content.

  Pass a `materialization_handle` returned by an authorized Record.

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

    Handles can materialize any supported Record, including data-source documents and
    communication-channel attachments. Data-source handles are bearer capabilities that are
    disclosed only on Records the actor was authorized to read.
    Optional MIME fields control source/export representation only; they are not identity or
    authorization inputs.

    Returns the normalized record including its materialized content.
    """,
    schema: @schema

  alias Jido.Action.Tool
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

    validate_input_mode_flags(has_handle?)
  end

  def validate_input_mode(_params, _opts),
    do: {:error, "download_document input must be an object"}

  defp validate_input_mode_flags(true), do: :ok
  defp validate_input_mode_flags(false), do: {:error, "provide materialization_handle"}

  @impl Jido.Action

  def run(%{materialization_handle: handle} = params, context) when is_binary(handle) do
    Materialization.materialize(
      handle,
      context,
      "Record materialization failed",
      materialization_options(params)
    )
  end

  def run(_params, _context),
    do: {:error, "Provide materialization_handle"}

  defp materialization_options(params) do
    %{}
    |> put_if_present(
      "document_mime_type",
      Map.get(params, :document_mime_type) || Map.get(params, "document_mime_type")
    )
    |> put_if_present(
      "export_mime_type",
      Map.get(params, :export_mime_type) || Map.get(params, "export_mime_type")
    )
    |> Map.reject(fn {_key, value} -> Helpers.blank?(value) end)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
