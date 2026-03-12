# lib/zaq_web/controllers/file_controller.ex

defmodule ZaqWeb.FileController do
  use ZaqWeb, :controller

  alias Zaq.Ingestion.FileExplorer

  @mime_types %{
    ".md" => "text/markdown",
    ".txt" => "text/plain",
    ".pdf" => "application/pdf",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  @doc """
  Serves a file from the ingestion storage.
  Path segments are joined and resolved against the FileExplorer base path.
  Rejects path traversal attempts via FileExplorer.resolve_path/1.
  """
  def show(conn, %{"path" => path_segments}) do
    relative_path = Path.join(path_segments)

    with {:ok, full_path} <- FileExplorer.resolve_path(relative_path),
         {:ok, stat} <- File.stat(full_path),
         false <- stat.type == :directory,
         {:ok, content} <- File.read(full_path) do
      ext = full_path |> Path.extname() |> String.downcase()
      content_type = Map.get(@mime_types, ext, "application/octet-stream")

      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header(
        "content-disposition",
        ~s(inline; filename="#{Path.basename(full_path)}")
      )
      |> send_resp(200, content)
    else
      {:error, :path_traversal} ->
        conn |> put_status(:forbidden) |> text("Forbidden")

      {:error, :enoent} ->
        conn |> put_status(:not_found) |> text("File not found")

      true ->
        # path is a directory
        conn |> put_status(:bad_request) |> text("Not a file")

      _ ->
        conn |> put_status(:internal_server_error) |> text("Could not read file")
    end
  end
end
