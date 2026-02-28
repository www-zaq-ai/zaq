# lib/zaq_web/live/bo/roles_live.ex

defmodule ZaqWeb.Live.BO.RolesLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts

  def mount(_params, _session, socket) do
    roles = Accounts.list_roles() |> Zaq.Repo.preload(:users)
    {:ok, assign(socket, :roles, roles)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    role = Accounts.get_role!(id)

    case Accounts.delete_role(role) do
      {:ok, _} ->
        roles = Accounts.list_roles() |> Zaq.Repo.preload(:users)

        {:noreply,
         socket
         |> put_flash(:info, "Role deleted.")
         |> assign(:roles, roles)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not delete role. It may still have users.")}
    end
  end
end
