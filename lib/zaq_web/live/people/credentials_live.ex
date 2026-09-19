defmodule ZaqWeb.Live.People.CredentialsLive do
  @moduledoc "Authenticated, write-only management of a Person's eligible AI credentials."

  use ZaqWeb, :live_view

  alias Zaq.Engine.Events
  alias ZaqWeb.Components.BOModal
  alias ZaqWeb.Components.DesignSystem.{Button, PersonHeader, SecretInput, Table}
  alias ZaqWeb.Components.PersonLayout

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> put_private(:person_credentials_token, session["person_session_token"])
     |> assign(
       page_title: "Credentials",
       credentials: [],
       manageable: false,
       credential_modal: nil,
       confirm_action: nil
     )
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

  def handle_event("open_credential_modal", %{"id" => id}, socket) do
    with true <- socket.assigns.manageable,
         {:ok, _credential_id, credential} <- credential(socket, id),
         true <- configurable?(credential) do
      {:noreply, assign(socket, credential_modal: credential, confirm_action: nil)}
    else
      _ -> denied(socket)
    end
  end

  def handle_event("close_credential_modal", _params, socket),
    do: {:noreply, assign(socket, credential_modal: nil)}

  def handle_event("open_credential_action", %{"id" => id, "action" => action}, socket)
      when action in ["revoke", "remove"] do
    with true <- socket.assigns.manageable,
         {:ok, _credential_id, credential} <- credential(socket, id),
         true <- credential.status != "absent",
         true <- action != "revoke" or credential.status != "revoked" do
      {:noreply,
       assign(socket,
         credential_modal: nil,
         confirm_action: %{action: action, credential: credential}
       )}
    else
      _ -> denied(socket)
    end
  end

  def handle_event("close_credential_action", _params, socket),
    do: {:noreply, assign(socket, confirm_action: nil)}

  def handle_event("confirm_credential_action", _params, socket) do
    case socket.assigns.confirm_action do
      %{action: "revoke", credential: credential} ->
        mutate(
          socket,
          credential.credential_id,
          :revoke_self_credential,
          %{},
          "Credential revoked."
        )

      %{action: "remove", credential: credential} ->
        mutate(
          socket,
          credential.credential_id,
          :remove_self_credential,
          %{},
          "Credential removed."
        )

      _ ->
        denied(socket)
    end
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
     |> assign(credential_modal: nil)
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
       |> assign(credential_modal: nil, confirm_action: nil)
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
     |> assign(credential_modal: nil, confirm_action: nil)
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

  defp policy_badge_tone(:required), do: :danger
  defp policy_badge_tone(_), do: :neutral

  defp status_badge_tone(%{
         status: "absent",
         personal_credential_policy: :required
       }),
       do: :danger

  defp status_badge_tone(%{status: "active"}), do: :success
  defp status_badge_tone(_), do: :neutral

  defp credential_type_label("api_key"), do: "API key"
  defp credential_type_label("oauth2"), do: "OAuth 2"
  defp credential_type_label(type), do: type

  defp credential_modal_title(%{status: "absent", name: name}), do: "Add #{name}"
  defp credential_modal_title(%{name: name}), do: "Edit #{name}"

  defp credential_action_label(%{status: "absent", auth_kind: "oauth2"}), do: "Connect"
  defp credential_action_label(%{status: "absent"}), do: "Add"
  defp credential_action_label(_), do: "Edit credential"

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
        <Table.table
          id="people-credentials-table"
          min_width="760px"
          wrapper_class="overflow-x-auto"
        >
          <:caption>
            <%= if @manageable do %>
              Configure credentials that ZAQ may use on your behalf.
            <% else %>
              You can view credential status, but you do not have permission to make changes.
            <% end %>
          </:caption>
          <:head>
            <Table.table_head_row>
              <Table.table_cell element={:th}>
                <Table.table_text label="Name" tone={:tertiary} />
              </Table.table_cell>
              <Table.table_cell element={:th}>
                <Table.table_text label="Provider" tone={:tertiary} />
              </Table.table_cell>
              <Table.table_cell element={:th}>
                <Table.table_text label="Credential type" tone={:tertiary} />
              </Table.table_cell>
              <Table.table_cell element={:th} align={:center}>
                <Table.table_text label="Personal policy" tone={:tertiary} />
              </Table.table_cell>
              <Table.table_cell element={:th} align={:center}>
                <Table.table_text label="Status" tone={:tertiary} />
              </Table.table_cell>
              <Table.table_cell element={:th} align={:right}>
                <span class="sr-only">Actions</span>
              </Table.table_cell>
            </Table.table_head_row>
          </:head>
          <:body>
            <Table.table_empty :if={@credentials == []} colspan={6}>
              No personal credentials available. Your administrator has not enabled personal authentication.
            </Table.table_empty>
            <Table.table_row
              :for={credential <- @credentials}
              id={"credential-#{credential.credential_id}"}
            >
              <Table.table_cell>
                <Table.table_text label={credential.name} />
                <p
                  :if={!configurable?(credential)}
                  class="zaq-text-caption"
                  style="color: var(--zaq-text-color-body-tertiary)"
                >
                  Personal use is disabled. You can remove retained authentication material.
                </p>
              </Table.table_cell>
              <Table.table_cell>
                <Table.table_text label={credential.provider} tone={:secondary} />
              </Table.table_cell>
              <Table.table_cell>
                <Table.table_text
                  label={credential_type_label(credential.auth_kind)}
                  tone={:secondary}
                />
              </Table.table_cell>
              <Table.table_cell align={:center}>
                <Table.table_badge
                  status={to_string(credential.personal_credential_policy)}
                  tone={policy_badge_tone(credential.personal_credential_policy)}
                  aria-label={policy_label(credential.personal_credential_policy)}
                >
                  {policy_label(credential.personal_credential_policy)}
                </Table.table_badge>
              </Table.table_cell>
              <Table.table_cell align={:center}>
                <Table.table_badge
                  id={"credential-status-#{credential.credential_id}"}
                  status={credential.status}
                  tone={status_badge_tone(credential)}
                  aria-label={status_label(credential.status)}
                >
                  {status_label(credential.status)}
                </Table.table_badge>
              </Table.table_cell>
              <Table.table_cell align={:right}>
                <Table.table_actions>
                  <Button.button
                    :if={@manageable && configurable?(credential)}
                    id={"credential-edit-#{credential.credential_id}"}
                    variant={if(credential.status == "absent", do: :secondary, else: :ghost)}
                    icon={if(credential.status == "absent", do: nil, else: "hero-pencil-square")}
                    icon_only={credential.status != "absent"}
                    title={credential_action_label(credential)}
                    aria-label={credential_action_label(credential)}
                    phx-click="open_credential_modal"
                    phx-value-id={credential.credential_id}
                  >
                    {credential_action_label(credential)}
                  </Button.button>
                  <Button.button
                    :if={@manageable && credential.status not in ["absent", "revoked"]}
                    id={"credential-revoke-#{credential.credential_id}"}
                    variant={:ghost}
                    icon="hero-no-symbol"
                    icon_only
                    title="Revoke credential"
                    aria-label="Revoke credential"
                    phx-click="open_credential_action"
                    phx-value-action="revoke"
                    phx-value-id={credential.credential_id}
                  />
                  <Button.button
                    :if={@manageable && credential.status != "absent"}
                    id={"credential-remove-#{credential.credential_id}"}
                    variant={:tertiary}
                    danger
                    icon="hero-trash"
                    icon_only
                    title="Remove credential"
                    aria-label="Remove credential"
                    phx-click="open_credential_action"
                    phx-value-action="remove"
                    phx-value-id={credential.credential_id}
                  />
                </Table.table_actions>
              </Table.table_cell>
            </Table.table_row>
          </:body>
        </Table.table>
      </section>

      <BOModal.form_dialog
        :if={@credential_modal}
        id="credential-form-dialog"
        title={credential_modal_title(@credential_modal)}
        cancel_event="close_credential_modal"
        max_width_class="zaq-modal--width-sm"
      >
        <.form
          :if={@credential_modal.auth_kind == "api_key"}
          for={to_form(%{}, as: :credential)}
          id={"credential-form-#{@credential_modal.credential_id}"}
          phx-submit="save_api_key"
          class="zaq-layout-stack"
        >
          <input type="hidden" name="credential_id" value={@credential_modal.credential_id} />
          <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
            Saved secrets are write-only. Enter the API key you want ZAQ to use on your behalf.
          </p>
          <SecretInput.secret_input
            id={"credential-api-key-#{@credential_modal.credential_id}"}
            name="credential[api_key]"
            label="API key"
            required
            autocomplete="new-password"
          />
        </.form>
        <div :if={@credential_modal.auth_kind == "oauth2"} class="zaq-layout-stack-tight">
          <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
            Continue to {@credential_modal.provider} to authorize ZAQ. Authentication details are never displayed.
          </p>
        </div>
        <:actions>
          <Button.button variant={:secondary} phx-click="close_credential_modal">Cancel</Button.button>
          <Button.button
            :if={@credential_modal.auth_kind == "api_key"}
            type="submit"
            form={"credential-form-#{@credential_modal.credential_id}"}
          >
            {if @credential_modal.status == "absent", do: "Add credential", else: "Save credential"}
          </Button.button>
          <Button.button
            :if={@credential_modal.auth_kind == "oauth2"}
            id={"credential-oauth-#{@credential_modal.credential_id}"}
            phx-click="connect_oauth"
            phx-value-id={@credential_modal.credential_id}
          >
            {if @credential_modal.status == "absent", do: "Connect", else: "Reconnect"}
          </Button.button>
        </:actions>
      </BOModal.form_dialog>

      <BOModal.confirm_dialog
        :if={@confirm_action && @confirm_action.action == "revoke"}
        id="credential-revoke-dialog"
        title="Revoke credential?"
        message="ZAQ will stop using this personal authentication until you add or reconnect it again."
        confirm_label="Revoke"
        cancel_event="close_credential_action"
        confirm_event="confirm_credential_action"
      />

      <BOModal.confirm_dialog
        :if={@confirm_action && @confirm_action.action == "remove"}
        id="credential-remove-dialog"
        title="Remove credential?"
        message="This removes your retained personal authentication material. The administrator-managed credential definition remains available."
        confirm_label="Remove"
        cancel_event="close_credential_action"
        confirm_event="confirm_credential_action"
      />
    </PersonLayout.person_layout>
    """
  end
end
