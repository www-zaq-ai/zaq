defmodule ZaqWeb.Live.People.CredentialsLive do
  @moduledoc "Authenticated, write-only management of a Person's eligible AI credentials."

  use ZaqWeb, :live_view

  alias Zaq.Engine.Events
  alias ZaqWeb.Components.DesignSystem.{Button, PersonHeader, SecretInput}
  alias ZaqWeb.Components.PersonLayout

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> put_private(:person_credentials_token, session["person_session_token"])
     |> assign(page_title: "Credentials", credentials: [], manageable: false)
     |> load_credentials()}
  end

  @impl true
  def handle_event("save_api_key", %{"credential_id" => id, "credential" => material}, socket) do
    mutate(
      socket,
      id,
      :put_self_credential,
      %{material: Map.take(material, ["api_key"])},
      "Credential saved."
    )
  end

  def handle_event("revoke_credential", %{"id" => id}, socket) do
    mutate(socket, id, :revoke_self_credential, %{}, "Credential revoked.")
  end

  def handle_event("remove_credential", %{"id" => id}, socket) do
    mutate(socket, id, :remove_self_credential, %{}, "Credential removed.")
  end

  def handle_event("connect_oauth", %{"id" => id}, socket) do
    with true <- socket.assigns.manageable,
         {:ok, credential_id, credential} <- credential(socket, id),
         true <- credential.auth_kind == "oauth2",
         op <-
           if(credential.status == "absent",
             do: :start_self_credential_oauth,
             else: :reconnect_self_credential_oauth
           ),
         {:ok, %{authorize_url: url}} <- command(socket, op, %{credential_id: credential_id}) do
      {:noreply, push_event(socket, "open_oauth_popup", %{url: url})}
    else
      false -> denied(socket)
      _ -> failed(socket, "Unable to start OAuth. Please try again.")
    end
  end

  # Popup data is notification-only. The authoritative state is always reread through
  # the authenticated Engine boundary after the callback has consumed its opaque attempt.
  def handle_event("oauth_popup_result", _params, socket) do
    {:noreply,
     socket
     |> load_credentials()
     |> put_flash(:info, "Connection status refreshed.")}
  end

  def handle_event("oauth_popup_blocked", _params, socket),
    do: failed(socket, "The OAuth window was blocked. Allow popups and try again.")

  def handle_event("retry", _params, socket), do: {:noreply, load_credentials(socket)}
  def handle_event(_, _, socket), do: denied(socket)

  defp mutate(socket, id, op, params, message) do
    with true <- socket.assigns.manageable,
         {:ok, credential_id, _credential} <- credential(socket, id),
         {:ok, _status} <- command(socket, op, Map.put(params, :credential_id, credential_id)) do
      {:noreply,
       socket
       |> load_credentials()
       |> put_flash(:info, message)}
    else
      false -> denied(socket)
      {:error, :forbidden} -> denied(socket)
      _ -> failed(socket, "Unable to update the credential. Please try again.")
    end
  end

  defp denied(socket) do
    {:noreply,
     socket
     |> load_credentials()
     |> put_flash(:error, "You do not have permission to manage credentials.")}
  end

  defp failed(socket, message),
    do: {:noreply, socket |> load_credentials() |> put_flash(:error, message)}

  defp credential(socket, id) do
    with {credential_id, ""} <- Integer.parse(to_string(id)),
         %{} = credential <-
           Enum.find(socket.assigns.credentials, &(&1.credential_id == credential_id)) do
      {:ok, credential_id, credential}
    else
      _ -> {:error, :not_found}
    end
  end

  defp load_credentials(socket) do
    case command(socket, :list_self_credentials) do
      {:ok, credentials} when is_list(credentials) ->
        assign(socket,
          credentials: credentials,
          manageable: manageable?(socket.assigns[:person_permissions])
        )

      {:error, :invalid_session} ->
        redirect(socket, to: "/people/login")

      _ ->
        socket
        |> assign(credentials: [], manageable: false)
        |> put_flash(:error, "Credentials are unavailable. Please try again.")
    end
  end

  defp manageable?(%MapSet{} = permissions),
    do:
      MapSet.member?(permissions, :access_profile) and
        MapSet.member?(permissions, :manage_credentials)

  defp manageable?(_), do: false

  defp command(socket, op, params \\ %{}) do
    Events.build_and_dispatch_invoke_event(
      Map.merge(params, %{op: op, token: socket.private.person_credentials_token}),
      :people_auth,
      event_opts: [confidential: true]
    ).response
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp status_label("active"), do: "Configured"
  defp status_label("expired"), do: "Expired"
  defp status_label("revoked"), do: "Revoked"
  defp status_label(_), do: "Not configured"

  defp policy_label(:required), do: "Required"
  defp policy_label(:optional), do: "Optional"
  defp policy_label(_), do: "Disabled"

  defp configurable?(credential),
    do: credential.personal_credential_policy in [:optional, :required]

  @impl true
  def render(assigns) do
    ~H"""
    <PersonLayout.person_layout flash={@flash} authenticated content_width={:wide}>
      <:header>
        <PersonHeader.person_header
          title="Credentials"
          description="Manage authentication used on your behalf. Saved secrets are never displayed."
          display_name={@current_person.full_name}
          credentials_access={true}
        />
      </:header>

      <section id="people-credentials" phx-hook="OAuthPopupListener" class="zaq-layout-stack">
        <div :if={@credentials == []} class="zaq-card-default zaq-layout-stack">
          <h2 class="zaq-text-h3">No personal credentials available</h2>
          <p class="zaq-text-body-sm">Your administrator has not enabled personal authentication.</p>
        </div>

        <article
          :for={credential <- @credentials}
          id={"credential-#{credential.credential_id}"}
          class="zaq-card-default zaq-layout-stack"
        >
          <div class="zaq-layout-inline justify-between flex-wrap">
            <div>
              <h2 class="zaq-text-h3">{credential.name}</h2>
              <p class="zaq-text-body-sm">{credential.provider} · {credential.auth_kind}</p>
            </div>
            <div class="zaq-layout-inline">
              <span class="zaq-pill">{policy_label(credential.personal_credential_policy)}</span>
              <span id={"credential-status-#{credential.credential_id}"} class="zaq-pill">
                {status_label(credential.status)}
              </span>
            </div>
          </div>

          <p :if={credential.personal_credential_policy == :required} class="zaq-text-body-sm">
            This credential is required when ZAQ acts on your behalf.
          </p>

          <.form
            :if={@manageable && configurable?(credential) && credential.auth_kind == "api_key"}
            for={to_form(%{}, as: :credential)}
            id={"credential-form-#{credential.credential_id}"}
            phx-submit="save_api_key"
            class="zaq-layout-stack"
          >
            <input type="hidden" name="credential_id" value={credential.credential_id} />
            <SecretInput.secret_input
              id={"credential-api-key-#{credential.credential_id}"}
              name="credential[api_key]"
              label="API key"
              required
              autocomplete="new-password"
            />
            <div class="zaq-layout-inline flex-wrap">
              <Button.button type="submit">{if credential.status == "absent",
                do: "Add API key",
                else: "Replace API key"}</Button.button>
            </div>
          </.form>

          <div
            :if={@manageable && configurable?(credential) && credential.auth_kind == "oauth2"}
            class="zaq-layout-inline"
          >
            <Button.button
              id={"credential-oauth-#{credential.credential_id}"}
              phx-click="connect_oauth"
              phx-value-id={credential.credential_id}
            >
              {if credential.status == "absent", do: "Connect", else: "Reconnect"}
            </Button.button>
          </div>

          <div :if={@manageable && credential.status != "absent"} class="zaq-layout-inline flex-wrap">
            <Button.button
              :if={credential.status != "revoked"}
              id={"credential-revoke-#{credential.credential_id}"}
              variant={:secondary}
              phx-click="revoke_credential"
              phx-value-id={credential.credential_id}
            >Revoke</Button.button>
            <Button.button
              id={"credential-remove-#{credential.credential_id}"}
              variant={:tertiary}
              danger
              phx-click="remove_credential"
              phx-value-id={credential.credential_id}
            >Remove</Button.button>
          </div>

          <p :if={!configurable?(credential)} class="zaq-text-body-sm">
            Personal use is disabled. You can remove retained authentication material.
          </p>

          <p :if={!@manageable} class="zaq-text-body-sm">
            You can view status, but you do not have permission to change this credential.
          </p>
        </article>
      </section>
    </PersonLayout.person_layout>
    """
  end
end
