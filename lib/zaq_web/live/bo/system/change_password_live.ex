defmodule ZaqWeb.Live.BO.System.ChangePasswordLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias ZaqWeb.ChangesetErrors
  alias ZaqWeb.Helpers.PasswordHelpers

  def mount(_params, session, socket) do
    user = Accounts.get_user!(session["user_id"])
    form_params = %{"email" => user.email || "", "password" => "", "password_confirmation" => ""}

    {:ok,
     socket
     |> assign(:user, user)
     |> assign(:form, to_form(form_params))
     |> PasswordHelpers.assign_password_feedback(form_params)
     |> assign(:error_message, nil)}
  end

  def handle_event("validate", params, socket) do
    form_params = PasswordHelpers.password_form_params(params)
    email = Map.get(params, "email", Map.get(socket.assigns.form.params || %{}, "email", ""))
    merged_form_params = Map.put(form_params, "email", email)

    {:noreply,
     socket
     |> assign(:form, to_form(merged_form_params))
     |> PasswordHelpers.assign_password_feedback(form_params)
     |> assign(:error_message, nil)}
  end

  def handle_event("change_password", params, socket) do
    form_params = PasswordHelpers.password_form_params(params)
    email = Map.get(params, "email")
    password = form_params["password"]
    confirmation = form_params["password_confirmation"]

    merged_form_params =
      Map.put(
        form_params,
        "email",
        email || Map.get(socket.assigns.form.params || %{}, "email", "")
      )

    socket =
      socket
      |> assign(:form, to_form(merged_form_params))
      |> PasswordHelpers.assign_password_feedback(form_params)

    if password != confirmation do
      {:noreply, assign(socket, :error_message, "Passwords do not match")}
    else
      socket
      |> update_password(password, email)
      |> then(&{:noreply, &1})
    end
  end

  defp update_password(socket, password, email) do
    attrs =
      if is_binary(email) do
        %{"password" => password, "email" => email}
      else
        %{"password" => password}
      end

    case Accounts.complete_bootstrap_onboarding(socket.assigns.user, attrs) do
      {:ok, user} ->
        socket
        |> assign(:user, user)
        |> put_flash(:info, "Password changed successfully")
        |> push_navigate(to: ~p"/bo/dashboard")

      {:error, changeset} ->
        assign(socket, :error_message, format_changeset_errors(changeset))
    end
  end

  defp format_changeset_errors(changeset) do
    ChangesetErrors.format(changeset)
  end
end
