defmodule Zaq.Agent.Tools.Ingestion.ConvertDocumentToMarkdown do
  @moduledoc """
  Converts a materialized download to Markdown through the Ingestion role.

  Use `DownloadDocument` first. Conversion does not save a file, index the
  document, or resolve any materialization handle.
  """

  alias Jido.Action.Tool
  alias Zaq.Contracts.Record
  alias Zaq.Ingestion.Events
  alias Zaq.NodeRouter

  use Zaq.Engine.Workflows.Action,
    name: "convert_document_to_markdown",
    description: """
    Convert a downloaded PDF, DOCX, PPTX, XLSX, CSV or Markdown file to Markdown.
    Pass the Record returned by DownloadDocument. PDF describes embedded images;
    Office formats ignore embedded images. Markdown and CSV take no image mode.
    Pass content, name and mime_type to CreateDocument to save the result.
    """,
    schema:
      Zoi.object(%{
        record: Record.zoi_type(verify_provenance: false, description: "Materialized download"),
        image_handling:
          Zoi.string(description: "Optional; describe for PDF or ignore for Office")
          |> Zoi.optional()
      }),
    output_schema:
      Zoi.object(%{
        content: Zoi.string(),
        name: Zoi.string(),
        mime_type: Zoi.string(),
        source:
          Zoi.object(%{
            record_id: Zoi.string(),
            name: Zoi.string() |> Zoi.optional(),
            mime_type: Zoi.string() |> Zoi.optional()
          })
      })

  @impl Jido.Action
  def on_before_validate_params(params) when is_map(params),
    do: {:ok, Tool.convert_params_using_schema(params, schema())}

  def on_before_validate_params(params), do: {:ok, params}

  @impl Jido.Action
  def run(params, context) do
    event =
      params
      |> Map.take([:record, :image_handling])
      |> Events.build_convert_document_event(actor: context[:actor])

    router = context[:node_router] || NodeRouter

    case router.dispatch(event).response do
      {:ok, markdown} -> {:ok, markdown}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :document_conversion_failed}
    end
  end
end
