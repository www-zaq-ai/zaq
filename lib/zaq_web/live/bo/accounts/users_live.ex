defmodule ZaqWeb.Live.BO.Accounts.UsersLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias ZaqWeb.Live.BO.Accounts.ListFlow

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:users, Accounts.list_users())
     |> assign(:current_path, "/bo/users")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    ListFlow.handle_delete(socket, id,
      fetch: &Accounts.get_user!/1,
      delete: &Accounts.delete_user/1,
      reload: &Accounts.list_users/0,
      assign_key: :users,
      success_message: "User deleted.",
      error_message: "Could not delete user."
    )
  end
end
