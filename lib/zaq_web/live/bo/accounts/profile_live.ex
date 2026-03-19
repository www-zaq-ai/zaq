defmodule ZaqWeb.Live.BO.Accounts.ProfileLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts

  def mount(_params, _session, socket) do
    user = Accounts.get_user!(socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(:current_path, "/bo/profile")
     |> assign(:page_title, "My Profile")
     |> assign(:user, user)}
  end
end
