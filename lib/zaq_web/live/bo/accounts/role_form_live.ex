defmodule ZaqWeb.Live.BO.Accounts.RoleFormLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, ~p"/bo/roles")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    role = %Accounts.Role{}
    changeset = Accounts.Role.changeset(role, %{})

    socket
    |> assign(:page_title, "New Role")
    |> assign(:role, role)
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    role = Accounts.get_role!(id)
    changeset = Accounts.Role.changeset(role, %{})

    socket
    |> assign(:page_title, "Edit Role")
    |> assign(:role, role)
    |> assign(:form, to_form(changeset))
  end

  def handle_event("validate", %{"role" => params}, socket) do
    changeset =
      socket.assigns.role
      |> Accounts.Role.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"role" => params}, socket) do
    save_role(socket, socket.assigns.live_action, params)
  end

  defp save_role(socket, :new, params) do
    case Accounts.create_role(params) do
      {:ok, _role} ->
        {:noreply,
         socket
         |> put_flash(:info, "Role created.")
         |> push_navigate(to: ~p"/bo/roles")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_role(socket, :edit, params) do
    case Accounts.update_role(socket.assigns.role, params) do
      {:ok, _role} ->
        {:noreply,
         socket
         |> put_flash(:info, "Role updated.")
         |> push_navigate(to: ~p"/bo/roles")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end
end
