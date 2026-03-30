defmodule ZaqWeb.Live.BO.Accounts.RoleFormLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias ZaqWeb.Live.BO.Accounts.FormFlow

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, ~p"/bo/roles")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    FormFlow.assign_entity_form(socket, :new, %{},
      assign_key: :role,
      new_title: "New Role",
      edit_title: "Edit Role",
      new_entity: fn -> %Accounts.Role{} end,
      load_entity: &Accounts.get_role!/1,
      changeset: &Accounts.Role.changeset/2
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    FormFlow.assign_entity_form(socket, :edit, %{"id" => id},
      assign_key: :role,
      new_title: "New Role",
      edit_title: "Edit Role",
      new_entity: fn -> %Accounts.Role{} end,
      load_entity: &Accounts.get_role!/1,
      changeset: &Accounts.Role.changeset/2
    )
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
    FormFlow.handle_save_result(socket, Accounts.create_role(params),
      success_message: "Role created.",
      to: ~p"/bo/roles"
    )
  end

  defp save_role(socket, :edit, params) do
    FormFlow.handle_save_result(socket, Accounts.update_role(socket.assigns.role, params),
      success_message: "Role updated.",
      to: ~p"/bo/roles"
    )
  end
end
