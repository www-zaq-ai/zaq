defmodule ZaqWeb.Live.BO.System.ResetPasswordLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias Zaq.Accounts.PasswordPolicy
  alias ZaqWeb.ChangesetErrors
  alias ZaqWeb.Helpers.PasswordHelpers

  def mount(%{"token" => token}, _session, socket) do
    case Accounts.verify_password_reset_token(token) do
      {:ok, user} ->
        form_params = %{"password" => "", "password_confirmation" => ""}

        {:ok,
         socket
         |> assign(:user, user)
         |> assign(:token, token)
         |> assign(:token_valid, true)
         |> assign(:form, to_form(form_params))
         |> assign(:error_message, nil)
         |> assign_password_feedback(form_params)}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:token_valid, false)
         |> assign(:user, nil)
         |> assign(:token, token)
         |> assign(:form, to_form(%{}))
         |> assign(:error_message, nil)
         |> assign(:password_requirements, PasswordPolicy.requirements_with_status(""))
         |> assign(:password_requirements_met?, false)
         |> assign(:password_confirmation_touched?, false)
         |> assign(:passwords_match?, false)}
    end
  end

  def handle_event("validate", params, socket) do
    form_params = password_form_params(params)

    {:noreply,
     socket
     |> assign(:form, to_form(form_params))
     |> assign_password_feedback(form_params)
     |> assign(:error_message, nil)}
  end

  def handle_event("reset_password", params, socket) do
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
      case Accounts.change_password(socket.assigns.user, %{password: password}) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> put_flash(:info, "Password reset successfully. Please sign in.")
           |> redirect(to: ~p"/bo/login")}

        {:error, changeset} ->
          {:noreply, assign(socket, :error_message, format_changeset_errors(changeset))}
      end
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
