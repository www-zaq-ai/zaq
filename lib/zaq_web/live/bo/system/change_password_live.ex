defmodule ZaqWeb.Live.BO.System.ChangePasswordLive do
  use ZaqWeb, :live_view
  use ZaqWeb.Live.BO.AuthLive

  import Zaq.Helpers, only: [blank?: 1]

  alias Zaq.Accounts
  alias Zaq.UserPortal
  alias Zaq.UserPortal.Onboarding
  alias ZaqWeb.BOSession
  alias ZaqWeb.ChangesetErrors
  alias ZaqWeb.Helpers.PasswordHelpers

  require Logger

  def mount(_params, session, socket) do
    user = socket.assigns.current_user
    welcome = Phoenix.Flash.get(socket.assigns.flash, :bootstrap_welcome)
    form_params = %{"email" => user.email || "", "password" => "", "password_confirmation" => ""}

    {:ok,
     socket
     |> assign(:user, user)
     |> assign(:bootstrap_browser, session["bootstrap_browser"])
     |> assign(:handoff_token, nil)
     |> assign(:form, to_form(form_params))
     |> PasswordHelpers.assign_password_feedback(form_params)
     |> assign(:error_message, nil)
     |> assign(:show_consent_modal, false)
     |> assign(:show_post_accept_modal, is_map(welcome))
     |> assign(:portal_metadata, if(is_map(welcome), do: %{"post_accept" => welcome}))
     |> assign(:portal_loading, false)
     |> assign(:pending_attrs, nil)
     |> assign(:current_year, Date.utc_today().year)}
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

  def handle_event(
        "change_password",
        params,
        %{assigns: %{user: %{must_change_password: true}}} = socket
      ) do
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

    cond do
      password != confirmation ->
        {:noreply, assign(socket, :error_message, "Passwords do not match")}

      # Catch a blank email inline, before the consent modal, rather than letting
      # it surface as a changeset error after the user has navigated the modal.
      blank?(merged_form_params["email"]) ->
        {:noreply, assign(socket, :error_message, "Email can't be blank")}

      true ->
        attrs = %{"password" => password, "email" => merged_form_params["email"]}

        # Fetch portal metadata asynchronously so a slow/unreachable portal never
        # blocks the submit handler (and therefore the decline flow). The consent
        # modal opens only once metadata resolves; see handle_async/3.
        {:noreply,
         socket
         |> assign(:pending_attrs, attrs)
         |> assign(:error_message, nil)
         |> assign(:portal_loading, true)
         |> start_async(:fetch_portal_metadata, fn ->
           UserPortal.client().fetch_onboarding("free")
         end)}
    end
  end

  def handle_event("change_password", _params, socket), do: {:noreply, socket}

  # Accept: register the ZAQ account first, then provision the portal. A portal
  # failure never blocks registration — the user keeps access and can retry
  # activation from the dashboard (see apply_onboarding/3).
  def handle_event("accept_portal_consent", _params, socket) do
    {:noreply, apply_onboarding(socket, :accepted)}
  end

  def handle_event("decline_portal_consent", _params, socket) do
    {:noreply, apply_onboarding(socket, :declined)}
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
     |> assign(:pending_attrs, nil)}
  end

  def handle_async(:fetch_portal_metadata, {:ok, result}, socket) do
    socket = assign(socket, :portal_loading, false)

    case result do
      {:ok, payload} ->
        if UserPortal.plan_active?(payload) do
          {:noreply,
           socket
           |> assign(:portal_metadata, get_in(payload, ["metadata"]) || %{})
           |> assign(:show_consent_modal, true)}
        else
          # Plan inactive — skip modal, create account without portal.
          {:noreply, apply_onboarding(socket, :unavailable)}
        end

      :unavailable ->
        # Portal unreachable — skip modal, create account without portal.
        {:noreply, apply_onboarding(socket, :unavailable)}
    end
  end

  def handle_async(:fetch_portal_metadata, {:exit, reason}, socket) do
    Logger.warning("Portal onboarding fetch failed: #{inspect(reason)}")
    {:noreply, socket |> assign(:portal_loading, false) |> apply_onboarding(:unavailable)}
  end

  defp apply_onboarding(socket, portal_consent) do
    apply_onboarding(socket, portal_consent, socket.assigns.pending_attrs)
  end

  defp apply_onboarding(socket, portal_consent, attrs) when is_map(attrs) do
    case Onboarding.complete_bootstrap_onboarding(socket.assigns.user, attrs, portal_consent) do
      {:ok, user} ->
        socket
        |> reset_consent_assigns()
        |> onboarding_success(user, portal_consent)

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> reset_consent_assigns()
        |> assign(:error_message, ChangesetErrors.format(changeset))

      # Email already on the portal (409): re-provisioning cannot help, so the
      # orchestrator recorded "portal_registered" (no activation banner). Surface
      # the bare guidance to fetch the key and set it on the ZAQ Router credential.
      {:error, {:provisioning_failed, {409, _body} = reason}} ->
        msg = UserPortal.provision_error(reason)

        provisioning_failed(socket, msg)

      # The account is already registered; only portal provisioning failed. Keep
      # the user moving — record nothing further here (the orchestrator already
      # recorded declined consent) and route them into the app with a message so
      # they can retry activation from the dashboard banner.
      {:error, {:provisioning_failed, reason}} ->
        msg = UserPortal.provision_error(reason)

        provisioning_failed(
          socket,
          "Your account is ready. #{msg} You can activate the ZAQ portal anytime from your dashboard."
        )
    end
  end

  defp apply_onboarding(socket, _portal_consent, _attrs), do: socket

  defp reset_consent_assigns(socket) do
    socket
    |> assign(:show_consent_modal, false)
    |> assign(:pending_attrs, nil)
  end

  defp onboarding_success(socket, user, :accepted) do
    metadata = (socket.assigns.portal_metadata || %{})["post_accept"] || %{}
    finish_registration(socket, user, {:welcome, welcome_copy(metadata)})
  end

  defp onboarding_success(socket, user, _portal_consent) do
    finish_registration(socket, user, {:dashboard, "Password changed successfully"})
  end

  defp provisioning_failed(socket, message) do
    # This outcome is returned only after this submission commits registration.
    registered = Accounts.get_user!(socket.assigns.user.id)
    socket |> reset_consent_assigns() |> finish_registration(registered, {:dashboard, message})
  end

  defp finish_registration(socket, user, destination) do
    if user.bo_session_nonce == socket.assigns.user.bo_session_nonce do
      socket |> assign(:user, user) |> navigate_after_registration(destination)
    else
      prepare_handoff(socket, user, destination)
    end
  end

  defp prepare_handoff(%{assigns: %{bootstrap_browser: browser}} = socket, user, destination)
       when is_binary(browser) do
    assign(socket,
      user: user,
      handoff_token: BOSession.bootstrap_handoff(user, browser, destination)
    )
  end

  defp prepare_handoff(socket, _user, _destination), do: redirect(socket, to: ~p"/bo/login")

  defp navigate_after_registration(socket, {:welcome, _}),
    do: assign(socket, :show_post_accept_modal, true)

  defp navigate_after_registration(socket, {:dashboard, message}) do
    socket |> put_flash(:info, message) |> push_navigate(to: ~p"/bo/dashboard")
  end

  defp welcome_copy(metadata) when is_map(metadata) do
    # Flash travels in the session cookie; bound Portal copy before carrying it across the POST.
    metadata
    |> Map.take(~w(title main_message secondary_message))
    |> Map.filter(fn {_key, value} -> is_binary(value) and byte_size(value) <= 512 end)
  end

  defp welcome_copy(_), do: %{}
end
