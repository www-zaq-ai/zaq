defmodule ZaqWeb.Live.BO.Accounts.RolesLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias ZaqWeb.Live.BO.Accounts.ListFlow

  defp list_roles_with_users, do: Accounts.list_roles() |> Zaq.Repo.preload(:users)

  def mount(_params, _session, socket) do
    roles = list_roles_with_users()

    {:ok,
     socket
     |> assign(:roles, roles)
     |> assign(:current_path, "/bo/roles")}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    ListFlow.handle_delete(socket, id,
      fetch: &Accounts.get_role!/1,
      delete: &Accounts.delete_role/1,
      reload: &list_roles_with_users/0,
      assign_key: :roles,
      success_message: "Role deleted.",
      error_message: "Could not delete role. It may still have users."
    )
  end
end
