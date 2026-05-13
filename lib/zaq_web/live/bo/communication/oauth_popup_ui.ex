defmodule ZaqWeb.Live.BO.Communication.OAuthPopupUI do
  @moduledoc false

  @spec open(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket, url) when is_binary(url) do
    socket
    |> Phoenix.Component.assign(:oauth_claim_modal, true)
    |> Phoenix.Component.assign(:oauth_claim_url, url)
    |> Phoenix.LiveView.push_event("open_oauth_popup", %{url: url})
  end

  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket) do
    socket
    |> Phoenix.Component.assign(:oauth_claim_modal, false)
    |> Phoenix.Component.assign(:oauth_claim_url, nil)
  end

  @spec blocked(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def blocked(socket) do
    socket
    |> close()
    |> Phoenix.LiveView.put_flash(
      :error,
      "Popup was blocked by the browser. Allow popups and try again."
    )
  end
end
