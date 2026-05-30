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
     |> assign(:error_message, nil)
     |> assign(:show_consent_modal, false)
     |> assign(:pending_attrs, nil)}
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
      attrs =
        if is_binary(email) do
          %{"password" => password, "email" => email}
        else
          %{"password" => password}
        end

      {:noreply,
       socket
       |> assign(:pending_attrs, attrs)
       |> assign(:show_consent_modal, true)
       |> assign(:error_message, nil)}
    end
  end

  def handle_event("accept_portal_consent", _params, socket) do
    socket |> do_complete_onboarding(:accepted) |> then(&{:noreply, &1})
  end

  def handle_event("decline_portal_consent", _params, socket) do
    socket |> do_complete_onboarding(:declined) |> then(&{:noreply, &1})
  end

  def handle_event("close_consent_modal", _params, socket) do
    {:noreply, socket |> assign(:show_consent_modal, false) |> assign(:pending_attrs, nil)}
  end

  defp do_complete_onboarding(socket, portal_consent) do
    attrs = socket.assigns.pending_attrs

    case Accounts.complete_bootstrap_onboarding(socket.assigns.user, attrs, portal_consent) do
      {:ok, user} ->
        socket
        |> assign(:user, user)
        |> assign(:show_consent_modal, false)
        |> assign(:pending_attrs, nil)
        |> put_flash(:info, "Password changed successfully")
        |> push_navigate(to: ~p"/bo/dashboard")

      {:error, changeset} ->
        socket
        |> assign(:show_consent_modal, false)
        |> assign(:pending_attrs, nil)
        |> assign(:error_message, format_changeset_errors(changeset))
    end
  end

  defp format_changeset_errors(changeset) do
    ChangesetErrors.format(changeset)
  end
end
