defmodule ZaqWeb.ChatDocumentsController do
  use ZaqWeb, :controller

  alias Zaq.Ingestion
  alias Zaq.Ingestion.{Document, Sidecar}
  alias Zaq.Ingestion.FileExplorer

  def index(conn, %{"prefix" => prefix}) do
    documents =
      prefix
      |> Ingestion.list_public_chat_documents()
      |> Enum.map(&serialize/1)

    json(conn, %{documents: documents})
  end

  def index(conn, _params), do: json(conn, %{documents: []})

  def show(conn, %{"id" => id}) do
    case Ingestion.get_public_chat_document(id) do
      nil -> json_error(conn, 404, "document not found")
      document -> json(conn, serialize(document, true))
    end
  end

  def file(conn, %{"id" => id}) do
    with document when not is_nil(document) <- Ingestion.get_public_chat_document(id),
         {:ok, path} <- FileExplorer.resolve_path(document.source),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type("application/pdf")
      |> put_resp_header("content-disposition", ~s(inline; filename="#{Path.basename(path)}"))
      |> send_file(200, path)
    else
      _ -> json_error(conn, 404, "document file not found")
    end
  end

  defp serialize(document, include_content? \\ false) do
    metadata = document.metadata || %{}

    %{
      id: document.id,
      source: document.source,
      title: document.title,
      summary: metadata["summary"] || metadata[:summary],
      suggestions: metadata["suggestions"] || metadata[:suggestions] || []
    }
    |> maybe_put_content(document, include_content?)
  end

  defp maybe_put_content(payload, document, true) do
    content_document = linked_sidecar(document) || document

    Map.merge(payload, %{
      content: content_document.content,
      content_type: content_document.content_type
    })
  end

  defp maybe_put_content(payload, _document, false), do: payload

  defp linked_sidecar(document) do
    case Sidecar.sidecar_source(document) do
      source when is_binary(source) -> Document.get_by_source(source)
      nil -> nil
    end
  end

  defp json_error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: %{message: message}})
  end
end
