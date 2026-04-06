defmodule ZaqWeb.Live.BO.System.ChangePasswordLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias ZaqWeb.ChangesetErrors
  alias ZaqWeb.Helpers.PasswordHelpers

  def mount(_params, session, socket) do
    user = Accounts.get_user!(session["user_id"])
    form_params = %{"password" => "", "password_confirmation" => ""}

    {:ok,
     socket
     |> assign(:user, user)
     |> assign(:form, to_form(form_params))
     |> assign_password_feedback(form_params)
     |> assign(:error_message, nil)}
  end

  def handle_event("validate", params, socket) do
    form_params = password_form_params(params)

    {:noreply,
     socket
     |> assign(:form, to_form(form_params))
     |> assign_password_feedback(form_params)
     |> assign(:error_message, nil)}
  end

  def handle_event("change_password", params, socket) do
    form_params = password_form_params(params)
    password = form_params["password"]
    confirmation = form_params["password_confirmation"]

    socket =
      socket
      |> assign(:form, to_form(form_params))
      |> assign_password_feedback(form_params)

    if password != confirmation do
      {:noreply, assign(socket, :error_message, "Passwords do not match")}
    else
      socket
      |> update_password(password)
      |> then(&{:noreply, &1})
    end
  end

  defp update_password(socket, password) do
    case Accounts.change_password(socket.assigns.user, %{password: password}) do
      {:ok, _user} ->
        socket
        |> put_flash(:info, "Password changed successfully")
        |> push_navigate(to: ~p"/bo/dashboard")

      {:error, changeset} ->
        assign(socket, :error_message, format_changeset_errors(changeset))
    end
  end

  defp password_form_params(params) do
    %{
      "password" => Map.get(params, "password", ""),
      "password_confirmation" => Map.get(params, "password_confirmation", "")
    }
  end

  defp assign_password_feedback(socket, params) do
    PasswordHelpers.assign_password_feedback(socket, params)
  end

  defp format_changeset_errors(changeset) do
    ChangesetErrors.format(changeset)
  end
end
