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
     |> assign(:portal_metadata, nil)
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
           |> assign(:show_consent_modal, true)}

        :unavailable ->
          # Portal is unreachable — there is nothing to consent to, so skip the
          # popup entirely. Onboarding records consent as declined and scaffolds
          # the (keyless) ZAQ Router provider so it is still listed for the user.
          {:noreply, apply_onboarding(socket, :unavailable)}
      end
    end
  end

  def handle_event("accept_portal_consent", _params, socket) do
    {:noreply, apply_onboarding(socket, :accepted)}
  end

  def handle_event("decline_portal_consent", _params, socket) do
    {:noreply, apply_onboarding(socket, :declined)}
  end

  def handle_event("close_consent_modal", _params, socket) do
    {:noreply, socket |> assign(:show_consent_modal, false) |> assign(:pending_attrs, nil)}
  end

  defp apply_onboarding(socket, portal_consent) do
    case Onboarding.complete_bootstrap_onboarding(
           socket.assigns.user,
           socket.assigns.pending_attrs,
           portal_consent
         ) do
      {:ok, user} ->
        socket
        |> assign(:user, user)
        |> assign(:show_consent_modal, false)
        |> assign(:pending_attrs, nil)
        |> onboarding_success_redirect(portal_consent)

      {:error, {:provisioning_failed, _reason}} ->
        # Registration succeeded (password changed) but portal provisioning failed.
        # Consent was recorded as declined — the user can retry from the dashboard.
        user = Accounts.get_user!(socket.assigns.user.id)

        socket
        |> assign(:user, user)
        |> assign(:show_consent_modal, false)
        |> assign(:pending_attrs, nil)
        |> put_flash(
          :info,
          "Password changed. ZAQ portal activation failed — you can retry it from the dashboard."
        )
        |> push_navigate(to: ~p"/bo/dashboard")

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> assign(:show_consent_modal, false)
        |> assign(:pending_attrs, nil)
        |> assign(:error_message, ChangesetErrors.format(changeset))
    end
  end

  # When the user activates the ZAQ portal, send them straight to ingestion so
  # they can start dropping files. Declining keeps the original dashboard flow.
  defp onboarding_success_redirect(socket, :accepted) do
    socket
    |> put_flash(
      :info,
      "You're all set! Your workspace is ready — just drop your files and ingest them to bring your company brain to life."
    )
    |> push_navigate(to: ~p"/bo/ingestion")
  end

  defp onboarding_success_redirect(socket, _portal_consent) do
    socket
    |> put_flash(:info, "Password changed successfully")
    |> push_navigate(to: ~p"/bo/dashboard")
  end

  # Single portal request for the bootstrap flow: returns the inner metadata map
  # when reachable so the consent modal can render without making its own call.
  defp fetch_portal_metadata do
    case portal_client().fetch_onboarding("free") do
      {:ok, payload} -> {:ok, get_in(payload, ["metadata"]) || %{}}
      :unavailable -> :unavailable
    end
  end

  defp portal_client, do: Application.get_env(:zaq, :user_portal_client, Zaq.UserPortal.Client)
end
