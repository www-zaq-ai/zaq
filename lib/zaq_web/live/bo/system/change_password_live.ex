defmodule ZaqWeb.Live.BO.System.ChangePasswordLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias Zaq.UserPortal.Onboarding
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
     |> assign(:show_post_accept_modal, false)
     |> assign(:portal_metadata, nil)
     |> assign(:pending_attrs, nil)
     |> assign(:consent_modal_error, nil)
     |> assign(:portal_consent_email, "")
     |> assign(:allow_email_override, false)}
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
      attrs = %{"password" => password, "email" => merged_form_params["email"]}

      socket =
        socket
        |> assign(:pending_attrs, attrs)
        |> assign(:error_message, nil)

      case fetch_portal_metadata() do
        {:ok, metadata} ->
          {:noreply,
           socket
           |> assign(:portal_metadata, metadata)
           |> assign(:portal_consent_email, merged_form_params["email"] || "")
           |> assign(:show_consent_modal, true)}

        :unavailable ->
          # Portal unreachable — skip modal, create account without portal.
          {:noreply, apply_onboarding(socket, :unavailable)}
      end
    end
  end

  # Accept: try portal provisioning first, create account only on success.
  def handle_event("accept_portal_consent", _params, socket) do
    email =
      if socket.assigns.allow_email_override and
           String.trim(socket.assigns.portal_consent_email || "") != "" do
        socket.assigns.portal_consent_email
      else
        socket.assigns.pending_attrs["email"]
      end

    case Onboarding.try_provision(email) do
      {:ok, _credential} ->
        attrs = Map.put(socket.assigns.pending_attrs, "email", email)
        {:noreply, apply_onboarding(socket, :pre_provisioned, attrs)}

      {:error, {409, body}} ->
        msg = Map.get(body, "message", "This email is already registered.")

        {:noreply,
         socket
         |> assign(:consent_modal_error, msg <> " Please use a different email address.")
         |> assign(:allow_email_override, true)
         |> assign(:portal_consent_email, "")}

      {:error, _reason} ->
        {:noreply,
         assign(
           socket,
           :consent_modal_error,
           "Portal activation failed — you can decline and retry from the dashboard."
         )}
    end
  end

  def handle_event("decline_portal_consent", _params, socket) do
    {:noreply, apply_onboarding(socket, :declined)}
  end

  def handle_event("portal_consent_email_change", %{"email" => email}, socket) do
    {:noreply, assign(socket, portal_consent_email: email, consent_modal_error: nil)}
  end

  def handle_event("close_post_accept_modal", _params, socket) do
    {:noreply,
     socket
     |> put_flash(
       :info,
       "You're all set! Your workspace is ready — drop your files to bring your company brain to life. Check your email to activate your account."
     )
     |> push_navigate(to: ~p"/bo/ingestion")}
  end

  def handle_event("close_consent_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_consent_modal, false)
     |> assign(:pending_attrs, nil)
     |> assign(:consent_modal_error, nil)
     |> assign(:allow_email_override, false)
     |> assign(:portal_consent_email, "")}
  end

  defp apply_onboarding(socket, portal_consent) do
    apply_onboarding(socket, portal_consent, socket.assigns.pending_attrs)
  end

  defp apply_onboarding(socket, portal_consent, attrs) do
    case Onboarding.complete_bootstrap_onboarding(socket.assigns.user, attrs, portal_consent) do
      {:ok, user} ->
        socket
        |> assign(:user, user)
        |> assign(:show_consent_modal, false)
        |> assign(:pending_attrs, nil)
        |> assign(:consent_modal_error, nil)
        |> assign(:allow_email_override, false)
        |> assign(:portal_consent_email, "")
        |> onboarding_success_redirect(portal_consent)

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> assign(:show_consent_modal, false)
        |> assign(:pending_attrs, nil)
        |> assign(:consent_modal_error, nil)
        |> assign(:allow_email_override, false)
        |> assign(:portal_consent_email, "")
        |> assign(:error_message, ChangesetErrors.format(changeset))
    end
  end

  defp onboarding_success_redirect(socket, consent)
       when consent in [:accepted, :pre_provisioned] do
    assign(socket, :show_post_accept_modal, true)
  end

  defp onboarding_success_redirect(socket, _portal_consent) do
    socket
    |> put_flash(:info, "Password changed successfully")
    |> push_navigate(to: ~p"/bo/dashboard")
  end

  defp fetch_portal_metadata do
    case portal_client().fetch_onboarding("free") do
      {:ok, payload} ->
        if plan_active?(payload),
          do: {:ok, get_in(payload, ["metadata"]) || %{}},
          else: :unavailable

      :unavailable ->
        :unavailable
    end
  end

  defp plan_active?(payload) do
    Map.get(payload, "plan_status") == "enabled" and
      Map.get(payload, "available", false) == true
  end

  defp portal_client, do: Application.get_env(:zaq, :user_portal_client, Zaq.UserPortal.Client)
end
