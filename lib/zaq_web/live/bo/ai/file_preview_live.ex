# lib/zaq_web/live/bo/ai/file_preview_live.ex

defmodule ZaqWeb.Live.BO.AI.FilePreviewLive do
  use ZaqWeb, :live_view

  alias ZaqWeb.Helpers.SizeFormat
  alias ZaqWeb.Live.BO.AI.FilePreviewData

  @impl true
  def mount(%{"path" => path_segments}, _session, socket) do
    relative_path = Path.join(path_segments)

    case FilePreviewData.load(relative_path, socket.assigns.current_user) do
      {:ok, preview} ->
        {:ok,
         socket
         |> assign(:current_path, "/bo/ingestion")
         |> assign(:preview, preview)}

      {:error, :unauthorized} ->
        {:ok,
         socket
         |> put_flash(:error, "You do not have access to this file.")
         |> push_navigate(to: "/bo/ingestion")}
    end
  end

  defdelegate format_size(bytes), to: SizeFormat
end
