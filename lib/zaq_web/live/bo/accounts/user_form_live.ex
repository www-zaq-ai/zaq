defmodule ZaqWeb.Live.BO.Accounts.UserFormLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias Zaq.Accounts.PasswordPolicy

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:roles, Accounts.list_roles())
     |> assign(:password_requirements, nil)}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    user = %Accounts.User{}
    changeset = Accounts.User.changeset(user, %{})

    socket
    |> assign(:page_title, "New User")
    |> assign(:user, user)
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user = Accounts.get_user!(id)
    changeset = Accounts.User.changeset(user, %{})

    socket
    |> assign(:page_title, "Edit User")
    |> assign(:user, user)
    |> assign(:form, to_form(changeset))
  end

  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.user
      |> Accounts.User.changeset(params)
      |> Map.put(:action, :validate)

    password = params["password"]

    password_requirements =
      if socket.assigns.live_action == :new and is_binary(password) and password != "" do
        PasswordPolicy.requirements_with_status(password)
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:password_requirements, password_requirements)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    save_user(socket, socket.assigns.live_action, params)
  end

  defp save_user(socket, :new, params) do
    case Accounts.create_user_with_password(params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User created.")
         |> push_navigate(to: ~p"/bo/users")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_user(socket, :edit, params) do
    case Accounts.update_user(socket.assigns.user, params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "User updated.")
         |> push_navigate(to: ~p"/bo/users")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end
end
