defmodule ZaqWeb.Live.BO.PortalConsentLive do
  @moduledoc """
  Owns the dashboard portal consent retry lifecycle.

  The component fetches onboarding metadata, renders the retry/offline UI, and
  handles portal provisioning events. Successful provisioning sends messages to
  the parent LiveView so the parent can update flash and current user assigns.
  """

  use ZaqWeb, :live_component

  import Zaq.Helpers, only: [blank?: 1]

  alias Zaq.UserPortal.Onboarding

  require Logger

  @impl true
  def mount(socket) do
    # Defaults only — the portal is never contacted from mount. Reaching the
    # portal here would block the BO header (and therefore every BO page) on a
    # synchronous HTTP call. Metadata is fetched asynchronously, once, after the
    # socket connects (see maybe_load_portal/1 + handle_async/3).
    {:ok,
     assign(socket,
       portal_reachable: false,
       portal_checked: false,
       portal_loaded: false,
       portal_metadata: nil,
       plan_enabled: false,
       plan_available: false,
       show_portal_banner: false,
       show_portal_consent_modal: false,
       show_post_accept_modal: false,
       portal_consent_accepted: false,
       portal_provision_error: nil,
       allow_email_override: false
     )}
  end

  @impl true
  def update(%{id: id, current_user: current_user}, socket) do
    {:ok,
     socket
     |> assign(:id, id)
     |> assign(:current_user, current_user)
     |> maybe_load_portal()
     |> assign_banner()
     |> assign(:require_portal_email, blank?(current_user.email))
     |> assign_new(:portal_consent_email, fn -> current_user.email || "" end)}
  end

  # Kicks off the portal metadata fetch exactly once, and only on a connected
  # socket. The dead (static) render and every later parent re-render skip it,
  # so page loads never wait on the portal. When the portal is unreachable the
  # banner simply never appears — the rest of ZAQ is unaffected.
  #
  # The fetch is also gated on banner eligibility: the banner can only ever show
  # to a user whose consent is "declined". Users who already accepted (or never
  # declined) never see it, so we never call the portal for them.
  defp maybe_load_portal(socket) do
    if connected?(socket) and not socket.assigns.portal_loaded and
         banner_eligible?(socket.assigns.current_user) do
      socket
      |> assign(:portal_loaded, true)
      |> start_async(:load_portal, fn -> Zaq.UserPortal.client().fetch_onboarding("free") end)
    else
      socket
    end
  end

  # Only a user who explicitly declined can be shown the re-activation banner.
  defp banner_eligible?(current_user), do: current_user.portal_consent == "declined"

  @impl true
  def handle_async(:load_portal, {:ok, result}, socket) do
    {portal_reachable, portal_metadata} =
      case result do
        {:ok, metadata} -> {true, metadata}
        :unavailable -> {false, nil}
      end

    {:noreply,
     socket
     |> assign(
       portal_reachable: portal_reachable,
       portal_checked: true,
       portal_metadata: portal_metadata,
       plan_enabled: Zaq.UserPortal.plan_enabled?(portal_metadata),
       plan_available: Zaq.UserPortal.plan_available?(portal_metadata)
     )
     |> assign_banner()}
  end

  def handle_async(:load_portal, {:exit, reason}, socket) do
    Logger.warning("Portal onboarding fetch failed: #{inspect(reason)}")
    {:noreply, assign(socket, portal_reachable: false, portal_checked: true)}
  end

  defp assign_banner(socket) do
    %{assigns: a} = socket

    assign(
      socket,
      :show_portal_banner,
      not a.portal_consent_accepted and
        a.portal_reachable and
        a.plan_enabled and
        a.plan_available and
        a.current_user.portal_consent == "declined"
    )
  end

  @impl true
  def render(assigns) do
    metadata = metadata(assigns.portal_metadata)

    assigns =
      assigns
      |> assign(:message, Map.get(assigns.portal_metadata || %{}, "message"))
      |> assign(:metadata, metadata)

    ~H"""
    <div id={@id}>
      <div
        :if={@show_portal_banner}
        class="flex items-center justify-between gap-4 rounded-lg border border-cyan-200 bg-cyan-50 px-4 py-2"
      >
        <div class="flex items-center gap-3 min-w-0">
          <svg
            class="w-5 h-5 text-cyan-600 shrink-0"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            viewBox="0 0 24 24"
          >
            <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
          </svg>
          <p class="font-mono text-[0.78rem] text-slate-600 truncate">
            {@metadata["banner_text"]}
          </p>
        </div>
        <button
          phx-click="show_portal_consent"
          phx-target={@myself}
          class="shrink-0 rounded-lg bg-cyan-600 px-4 py-1.5 font-mono text-[0.75rem] font-semibold text-white hover:bg-cyan-700 transition-colors"
        >
          Activate
        </button>
      </div>

      <div
        :if={@portal_checked and not @portal_reachable}
        class="flex items-center gap-3 rounded-lg border border-slate-200 bg-slate-50 px-4 py-2"
      >
        <svg
          class="w-4 h-4 text-slate-400 shrink-0"
          fill="none"
          stroke="currentColor"
          stroke-width="1.8"
          viewBox="0 0 24 24"
        >
          <path d="M18.364 5.636a9 9 0 1 1-12.728 0" /><path d="M12 2v7" />
        </svg>
        <p class="font-mono text-[0.75rem] text-slate-500">
          ZAQ portal is not reachable in this environment - portal features are unavailable.
        </p>
      </div>

      <ZaqWeb.Components.PortalConsentModal.portal_consent_modal
        :if={@portal_reachable}
        show={@show_portal_consent_modal}
        metadata={@metadata}
        target={@myself}
        on_decline="close_portal_consent_modal"
        require_email={@require_portal_email}
        allow_email_override={@allow_email_override}
        email={@portal_consent_email}
        on_email_change="portal_consent_email_change"
        available={@plan_available}
        error={@portal_provision_error}
      />

      <ZaqWeb.Components.PortalConsentModal.portal_post_accept_modal
        show={@show_post_accept_modal}
        post_accept={@metadata["post_accept"]}
        target={@myself}
        on_close="close_post_accept_modal"
      />
    </div>
    """
  end

  @impl true
  def handle_event("show_portal_consent", _params, socket) do
    {:noreply, assign(socket, show_portal_consent_modal: true, portal_provision_error: nil)}
  end

  @impl true
  def handle_event("close_portal_consent_modal", _params, socket) do
    {:noreply,
     assign(socket,
       show_portal_consent_modal: false,
       portal_provision_error: nil,
       allow_email_override: false
     )}
  end

  @impl true
  def handle_event("close_post_accept_modal", _params, socket) do
    {:noreply,
     socket
     |> put_flash(
       :info,
       "You're all set! Your workspace is ready — drop your files to bring your company brain to life. Check your email to activate your account."
     )
     |> push_navigate(to: ~p"/bo/ingestion")}
  end

  @impl true
  def handle_event("portal_consent_email_change", %{"email" => email}, socket) do
    {:noreply, assign(socket, portal_consent_email: email, portal_provision_error: nil)}
  end

  @impl true
  def handle_event("accept_portal_consent", _params, socket) do
    case Onboarding.activate_portal(
           socket.assigns.current_user,
           socket.assigns.portal_consent_email
         ) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:portal_consent_accepted, true)
         |> assign(:show_portal_banner, false)
         |> assign(:show_portal_consent_modal, false)
         |> assign(:show_post_accept_modal, true)
         |> assign(:require_portal_email, false)
         |> assign(:allow_email_override, false)
         |> assign(:portal_consent_email, updated_user.email)
         |> assign(:portal_provision_error, nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           portal_provision_error: email_error_message(changeset),
           show_portal_consent_modal: true
         )}

      {:error, reason} ->
        {error_msg, mode} = Zaq.UserPortal.provision_error(reason)

        {:noreply,
         socket
         |> assign(:portal_provision_error, error_msg)
         |> assign(:show_portal_consent_modal, true)
         |> assign(:allow_email_override, mode == :allow_override)
         |> then(fn s ->
           if mode == :allow_override and not socket.assigns.require_portal_email,
             do: assign(s, :portal_consent_email, ""),
             else: s
         end)}
    end
  end

  defp email_error_message(changeset) do
    case changeset.errors[:email] do
      {message, _opts} -> "Email #{message}."
      _ -> "Please enter a valid email address."
    end
  end

  defp metadata(portal_metadata), do: get_in(portal_metadata || %{}, ["metadata"]) || %{}
end
