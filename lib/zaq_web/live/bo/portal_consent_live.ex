defmodule ZaqWeb.Live.BO.PortalConsentLive do
  @moduledoc """
  Owns the dashboard portal consent retry lifecycle.

  The component fetches onboarding metadata, renders the retry/offline UI, and
  handles portal provisioning events. Successful provisioning sends messages to
  the parent LiveView so the parent can update flash and current user assigns.
  """

  use ZaqWeb, :live_component

  alias Zaq.UserPortal.Onboarding

  @impl true
  def mount(socket) do
    # Reachability + metadata are fetched exactly once, when the component is
    # first added to the page — never again on parent re-renders.
    {portal_reachable, portal_metadata} = load_portal_onboarding()

    {:ok,
     assign(socket,
       portal_reachable: portal_reachable,
       portal_metadata: portal_metadata,
       show_portal_consent_modal: false,
       portal_provision_error: nil
     )}
  end

  @impl true
  def update(%{id: id, current_user: current_user}, socket) do
    {:ok,
     socket
     |> assign(:id, id)
     |> assign(:current_user, current_user)
     |> assign(
       :show_portal_banner,
       socket.assigns.portal_reachable and current_user.portal_consent == "declined"
     )
     |> assign(:require_portal_email, blank?(current_user.email))
     |> assign_new(:portal_consent_email, fn -> current_user.email || "" end)}
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
        class="mb-6 flex items-center justify-between gap-4 rounded-xl border border-cyan-200 bg-cyan-50 px-5 py-4"
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
        :if={not @portal_reachable}
        class="mb-6 flex items-center gap-3 rounded-xl border border-slate-200 bg-slate-50 px-5 py-4"
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
        email={@portal_consent_email}
        on_email_change="portal_consent_email_change"
        error={@portal_provision_error}
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
    {:noreply, assign(socket, show_portal_consent_modal: false, portal_provision_error: nil)}
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
        send(self(), {:portal_consent_accepted, updated_user})

        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:show_portal_banner, false)
         |> assign(:show_portal_consent_modal, false)
         |> assign(:require_portal_email, false)
         |> assign(:portal_consent_email, updated_user.email)
         |> assign(:portal_provision_error, nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           portal_provision_error: email_error_message(changeset),
           show_portal_consent_modal: true
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           portal_provision_error: provision_error_message(reason),
           show_portal_consent_modal: true
         )}
    end
  end

  # Surface the portal's own message (e.g. a 409 "user already exists") when the
  # portal actually responded. Only genuine transport failures — where no
  # response body is available — fall back to the "could not reach" message.
  defp provision_error_message({_status, %{"message" => message}})
       when is_binary(message) and message != "" do
    message
  end

  defp provision_error_message(_reason) do
    "Could not reach the ZAQ portal. Please try again later."
  end

  defp email_error_message(changeset) do
    case changeset.errors[:email] do
      {message, _opts} -> "Email #{message}."
      _ -> "Please enter a valid email address."
    end
  end

  defp load_portal_onboarding do
    case portal_client().fetch_onboarding("free") do
      {:ok, metadata} -> {true, metadata}
      :unavailable -> {false, nil}
    end
  end

  defp portal_client, do: Application.get_env(:zaq, :user_portal_client, Zaq.UserPortal.Client)

  defp metadata(portal_metadata), do: get_in(portal_metadata || %{}, ["metadata"]) || %{}

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")
end
