defmodule ZaqWeb.Live.BO.Accounts.UserFormLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias Zaq.Accounts.PasswordPolicy
  alias Zaq.Engine.Notifications.WelcomeEmail

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
    user = %Accounts.User{}
    changeset = Accounts.User.changeset(user, %{})

    socket
    |> assign(:page_title, "New User")
    |> assign(:user, user)
    |> assign(:form, to_form(changeset))
    |> assign(:password_requirements, nil)
    |> reset_password_change_state()
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user = Accounts.get_user!(id)
    changeset = Accounts.User.changeset(user, %{})

    socket
    |> assign(:page_title, "Edit User")
    |> assign(:user, user)
    |> assign(:form, to_form(changeset))
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
    case Accounts.create_user_with_password(params) do
      {:ok, user} ->
        WelcomeEmail.deliver(user)

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
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, fn message -> "#{field}: #{message}" end)
    end)
    |> Enum.join(", ")
  end
end
