defmodule ZaqWeb.Live.BO.Accounts.UserFormLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias Zaq.Accounts.PasswordPolicy
  alias Zaq.Engine.Notifications.WelcomeEmail
  alias ZaqWeb.ChangesetErrors
  alias ZaqWeb.Live.BO.Accounts.FormFlow

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, ~p"/bo/users")
     |> assign(:roles, Accounts.list_roles())
     |> assign(:password_requirements, nil)
     |> reset_password_change_state()}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> FormFlow.assign_entity_form(:new, %{},
      assign_key: :user,
      new_title: "New User",
      edit_title: "Edit User",
      new_entity: fn -> %Accounts.User{} end,
      load_entity: &Accounts.get_user!/1,
      changeset: &Accounts.User.changeset/2
    )
    |> assign(:password_requirements, nil)
    |> reset_password_change_state()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> FormFlow.assign_entity_form(:edit, %{"id" => id},
      assign_key: :user,
      new_title: "New User",
      edit_title: "Edit User",
      new_entity: fn -> %Accounts.User{} end,
      load_entity: &Accounts.get_user!/1,
      changeset: &Accounts.User.changeset/2
    )
    |> assign(:password_requirements, nil)
    |> reset_password_change_state()
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

  def handle_event("toggle_password_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:password_change_open?, true)
     |> clear_password_change_error()}
  end

  def handle_event("cancel_password_change", _params, socket) do
    {:noreply, reset_password_change_state(socket)}
  end

  def handle_event("validate_password_change", %{"password_change" => params}, socket) do
    {:noreply,
     socket
     |> assign(
       :password_change_form,
       to_form(password_change_params(params), as: :password_change)
     )
     |> assign_password_change_feedback(params)
     |> clear_password_change_error()}
  end

  def handle_event("save_password_change", %{"password_change" => params}, socket) do
    case Accounts.change_user_password(socket.assigns.current_user, socket.assigns.user, params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Password updated.")
         |> assign(:user, Accounts.get_user!(socket.assigns.user.id))
         |> reset_password_change_state()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:password_change_open?, true)
         |> assign(:password_change_form, to_form(changeset, as: :password_change))
         |> assign_password_change_feedback(params)
         |> assign(:password_change_error, format_changeset_errors(changeset))}
    end
  end

  defp save_user(socket, :new, params) do
    result = Accounts.create_user_with_password(params)

    case result do
      {:ok, user} -> WelcomeEmail.deliver(user)
      _ -> :ok
    end

    FormFlow.handle_save_result(socket, result,
      success_message: "User created.",
      to: ~p"/bo/users"
    )
  end

  defp save_user(socket, :edit, params) do
    FormFlow.handle_save_result(socket, Accounts.update_user(socket.assigns.user, params),
      success_message: "User updated.",
      to: ~p"/bo/users"
    )
  end

  defp reset_password_change_state(socket) do
    params = password_change_params()

    socket
    |> assign(:password_change_open?, false)
    |> assign(:password_change_form, to_form(params, as: :password_change))
    |> assign_password_change_feedback(params)
    |> assign(:password_change_error, nil)
  end

  defp clear_password_change_error(socket), do: assign(socket, :password_change_error, nil)

  defp password_change_params(params \\ %{}) do
    %{
      "current_password" => Map.get(params, "current_password", ""),
      "new_password" => Map.get(params, "new_password", ""),
      "new_password_confirmation" => Map.get(params, "new_password_confirmation", "")
    }
  end

  defp assign_password_change_feedback(socket, params) do
    new_password = Map.get(params, "new_password", "")
    confirmation = Map.get(params, "new_password_confirmation", "")

    socket
    |> assign(
      :password_change_requirements,
      PasswordPolicy.requirements_with_status(new_password)
    )
    |> assign(:password_change_requirements_met?, PasswordPolicy.valid_password?(new_password))
    |> assign(:password_change_confirmation_touched?, confirmation != "")
    |> assign(:password_change_match?, confirmation != "" and new_password == confirmation)
  end

  defp format_changeset_errors(changeset) do
    ChangesetErrors.format(changeset)
  end
end
