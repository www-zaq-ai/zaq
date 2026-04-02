defmodule ZaqWeb.Live.BO.PreviewHelpers do
  @moduledoc """
  Shared helpers for BO file preview modal state transitions.
  """

  alias ZaqWeb.Live.BO.AI.FilePreviewData

  @unauthorized_message "You do not have access to this file."
  @not_previewable_message "Preview is not available for this file type."

  @spec previewable_path?(String.t()) :: boolean()
  def previewable_path?(path), do: FilePreviewData.previewable_path?(path)

  @spec open_preview(Phoenix.LiveView.Socket.t(), String.t(), atom() | nil) ::
          Phoenix.LiveView.Socket.t()
  def open_preview(socket, path, modal_assign \\ nil) do
    if previewable_path?(path) do
      case FilePreviewData.load(path, socket.assigns.current_user) do
        {:ok, preview} ->
          socket
          |> Phoenix.Component.assign(:preview, preview)
          |> maybe_set_modal(modal_assign)

        {:error, :unauthorized} ->
          Phoenix.LiveView.put_flash(socket, :error, @unauthorized_message)
      end
    else
      Phoenix.LiveView.put_flash(socket, :error, @not_previewable_message)
    end
  end

  @spec close_preview(Phoenix.LiveView.Socket.t(), atom() | nil) :: Phoenix.LiveView.Socket.t()
  def close_preview(socket, modal_assign \\ nil) do
    socket
    |> Phoenix.Component.assign(:preview, nil)
    |> maybe_clear_modal(modal_assign)
  end

  defp maybe_set_modal(socket, nil), do: socket

  defp maybe_set_modal(socket, modal_assign),
    do: Phoenix.Component.assign(socket, modal_assign, :preview)

  defp maybe_clear_modal(socket, nil), do: socket

  defp maybe_clear_modal(socket, modal_assign),
    do: Phoenix.Component.assign(socket, modal_assign, nil)
end
