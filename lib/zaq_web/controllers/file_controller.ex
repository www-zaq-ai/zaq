# lib/zaq_web/controllers/file_controller.ex

defmodule ZaqWeb.FileController do
  use ZaqWeb, :controller

  alias Zaq.Ingestion
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
  Also supports volume-aware resolution for files ingested from specific volumes.
  """
  def show(conn, %{"path" => path_segments}) do
    relative_path = Path.join(path_segments)

    if Ingestion.can_access_file?(relative_path, conn.assigns.current_user) do
      with {:ok, full_path} <- resolve_path_with_fallback(relative_path),
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
          conn |> put_status(:bad_request) |> text("Not a file")

        _ ->
          conn |> put_status(:internal_server_error) |> text("Could not read file")
      end
    else
      conn |> put_status(:forbidden) |> text("Access denied")
    end
  end

  # Resolves a path, trying volume-aware resolution if standard resolution fails
  defp resolve_path_with_fallback(relative_path) do
    case FileExplorer.resolve_path(relative_path) do
      {:ok, full_path} ->
        {:ok, full_path}

      {:error, :enoent} ->
        try_find_in_volumes(relative_path)

      error ->
        error
    end
  end

  defp try_find_in_volumes(relative_path) do
    volumes = FileExplorer.list_volumes()

    Enum.reduce_while(Map.keys(volumes), {:error, :enoent}, fn volume_name, acc ->
      case FileExplorer.resolve_path(volume_name, relative_path) do
        {:ok, full_path} -> {:halt, {:ok, full_path}}
        _ -> {:cont, acc}
      end
    end)
  end
end
