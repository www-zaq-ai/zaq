# lib/zaq_web/controllers/file_controller.ex

defmodule ZaqWeb.FileController do
  use ZaqWeb, :controller

  alias Zaq.Ingestion
  alias Zaq.Storage.FileExplorer
  alias ZaqWeb.Live.BO.AI.FilePreviewData

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
  Serves raw content named by a signed preview reference.
  """
  def show_ref(conn, %{"token" => token}) do
    case FilePreviewData.load_raw(token, conn.assigns.current_user) do
      {:ok, %{content: content, filename: filename, content_type: content_type}} ->
        conn
        |> put_resp_content_type(content_type || "application/octet-stream")
        |> put_resp_header(
          "content-disposition",
          ~s(inline; filename="#{Path.basename(filename)}")
        )
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, content)

      {:error, :unauthorized} ->
        conn |> put_status(:forbidden) |> text("Access denied")

      {:error, _reason} ->
        conn |> put_status(:not_found) |> text("File not found")
    end
  end

  @doc """
  Serves a file from the ingestion storage.
  Path segments are joined and resolved against the FileExplorer base path.
  Rejects path traversal attempts via FileExplorer.resolve_path/1.
  """
  def show(conn, %{"path" => path_segments}) do
    relative_path = Path.join(path_segments)

    if Ingestion.can_access_file?(relative_path, conn.assigns.current_user) do
      with {:ok, full_path} <- FileExplorer.resolve_path(relative_path, legacy_storage_opts()),
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

  defp legacy_storage_opts do
    case Application.get_env(:zaq, Zaq.Ingestion, [])[:base_path] do
      nil -> []
      base_path -> [storage_config: [base_path: base_path, volumes: %{}]]
    end
  end
end
