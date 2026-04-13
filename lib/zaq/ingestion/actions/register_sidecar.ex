defmodule Zaq.Ingestion.Actions.RegisterSidecar do
  @moduledoc """
  After `ConvertToMarkdown`, upserts Document records for the source file and its
  sidecar (when one was produced). This is what makes the sidecar row visible in the
  file browser without running the full chunking/embedding pipeline.

  For non-sidecar files (plain `.md`, `.txt`, `.csv`) where `md_path == file_path`,
  only the source Document record is upserted.
  """

  use Jido.Action,
    name: "register_sidecar",
    description: "Upserts Document records for source and sidecar after conversion.",
    schema: [
      file_path: [type: :string, required: true, doc: "Absolute path to the source file"],
      md_path: [
        type: :string,
        required: true,
        doc: "Absolute path to the sidecar (or file_path if no sidecar)"
      ],
      md_content: [type: :string, required: true, doc: "Markdown content from ConvertToMarkdown"]
    ]

  alias Zaq.Ingestion.{Document, Sidecar, SourcePath}

  @impl true
  def run(%{file_path: file_path, md_path: md_path, md_content: md_content}, _context) do
    has_sidecar = md_path != file_path

    with {:ok, source} <- SourcePath.absolute_to_source(file_path),
         {:ok, sidecar_source} <- maybe_sidecar_source(has_sidecar, md_path),
         {:ok, doc} <- upsert_source(source, md_content, sidecar_source),
         :ok <- maybe_upsert_sidecar(has_sidecar, sidecar_source, md_content, source) do
      {:ok, %{document_id: doc.id}}
    end
  end

  defp maybe_sidecar_source(false, _md_path), do: {:ok, nil}

  defp maybe_sidecar_source(true, md_path), do: SourcePath.absolute_to_source(md_path)

  defp upsert_source(source, content, sidecar_source) do
    Document.upsert(%{
      source: source,
      content: content,
      metadata: Sidecar.source_metadata(sidecar_source)
    })
  end

  defp maybe_upsert_sidecar(false, _sidecar_source, _content, _source), do: :ok

  defp maybe_upsert_sidecar(true, sidecar_source, content, source) do
    case Document.upsert(%{
           source: sidecar_source,
           content: content,
           metadata: Sidecar.sidecar_metadata(source)
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
