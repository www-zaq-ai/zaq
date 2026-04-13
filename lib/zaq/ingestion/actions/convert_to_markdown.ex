defmodule Zaq.Ingestion.Actions.ConvertToMarkdown do
  @moduledoc """
  Converts the source file to markdown content.

  - For formats that need conversion (PDF, DOCX, XLSX, images): runs the Python pipeline
    and writes a `.md` sidecar file alongside the original. If the sidecar already exists
    it is read directly — conversion is skipped.
  - For plain `.md`, `.txt`, `.csv` files: reads content directly; no sidecar is written.

  Returns the markdown content, the effective markdown path, and whether conversion ran.
  The `converted: false` flag signals to the plan that this file was already converted
  in a prior run (upload-only checkpoint), enabling skip logic in Phase 3.
  """

  use Jido.Action,
    name: "convert_to_markdown",
    description: "Converts the source file to markdown. Skips if a sidecar .md already exists.",
    schema: [
      file_path: [
        type: :string,
        required: true,
        doc: "Absolute path to the source file (resolved by UploadFile)"
      ]
    ]

  alias Zaq.Ingestion.Sidecar

  require Logger

  @impl true
  def run(%{file_path: file_path}, _context) do
    processor = Application.get_env(:zaq, :document_processor, Zaq.Ingestion.DocumentProcessor)
    md_path = Sidecar.sidecar_path_for(file_path) || file_path
    sidecar_existed = md_path != file_path and File.exists?(md_path)

    case processor.read_as_markdown(file_path) do
      {:ok, content} ->
        label = if sidecar_existed, do: "sidecar reused", else: "converted"
        Logger.info("[ConvertToMarkdown] #{label}: #{md_path}")

        {:ok,
         %{
           file_path: file_path,
           md_path: md_path,
           md_content: content,
           converted: not sidecar_existed
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
