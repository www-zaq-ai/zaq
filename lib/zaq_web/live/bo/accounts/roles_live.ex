defmodule ZaqWeb.Live.BO.Accounts.RolesLive do
  @moduledoc "BO role listing; deletion requires current server-side role authority."
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias ZaqWeb.Live.BO.Accounts.ListFlow
  alias ZaqWeb.Live.BO.Accounts.Mutations

  defp list_roles_with_users do
    Accounts.list_roles_with_user_counts()
    |> Enum.map(fn role -> Map.put(role, :meta_json, Jason.encode!(role.meta || %{})) end)
  end

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
      delete: fn role ->
        Mutations.run(socket.assigns.current_user, :delete_role, %{id: role.id})
      end,
      reload: &list_roles_with_users/0,
      assign_key: :roles,
      success_message: "Role deleted.",
      error_message: "Could not delete role. It may still have users."
    )
  end
end
