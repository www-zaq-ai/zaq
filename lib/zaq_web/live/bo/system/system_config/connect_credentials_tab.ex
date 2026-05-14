defmodule ZaqWeb.Live.BO.System.SystemConfig.ConnectCredentialsTab do
  @moduledoc """
  Tab component for the BO system configuration page.
  """
  use ZaqWeb, :html

  alias ZaqWeb.Components.BOModal
  alias ZaqWeb.Components.ConnectCredentialForm

  attr :credentials, :list, required: true
  attr :grants_modal, :boolean, required: true
  attr :selected_credential, :any, required: true
  attr :selected_grants, :list, required: true
  attr :selected_connect_refresh_schedule, :map, required: true
  attr :credential_modal, :boolean, required: true
  attr :credential_form, :any, required: true
  attr :credential_changeset, :any, required: true
  attr :credential_errors, :list, required: true

  def panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa]">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">Auth Credentials</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          Reusable Data Source and MCP credentials with related grants.
        </p>
      </div>

      <div :if={@credentials == []} class="px-8 py-10 text-center">
        <p class="font-mono text-[0.85rem] text-black/50">No credentials configured yet.</p>
      </div>

      <div :if={@credentials != []} class="divide-y divide-black/[0.06]">
        <div
          :for={credential <- @credentials}
          class="px-8 py-4 flex items-center justify-between gap-4"
        >
          <div>
            <p class="font-mono text-[0.82rem] font-semibold text-black">{credential.name}</p>
            <p class="font-mono text-[0.7rem] text-black/50 mt-0.5">
              {credential.provider} · {credential.auth_kind}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <button
              type="button"
              phx-click="open_connect_grants"
              phx-value-id={credential.id}
              class="font-mono text-[0.72rem] px-3 py-1.5 rounded-lg border border-black/10 text-black/70 hover:bg-black/[0.04]"
            >
              View grants
            </button>
            <button
              type="button"
              phx-click="edit_connect_credential"
              phx-value-id={credential.id}
              class="font-mono text-[0.72rem] px-3 py-1.5 rounded-lg border border-black/10 text-black/70 hover:bg-black/[0.04]"
            >
              Edit
            </button>
          </div>
        </div>
      </div>
    </div>

    <BOModal.form_dialog
      :if={@grants_modal}
      id="connect-grants-modal"
      cancel_event="close_connect_grants_modal"
      title={
        if @selected_credential,
          do: "Grants — #{@selected_credential.name}",
          else: "Grants"
      }
      max_width_class="max-w-3xl"
    >
      <div :if={@selected_grants == []} class="py-8 text-center">
        <p class="font-mono text-[0.8rem] text-black/50">No grants for this credential.</p>
      </div>

      <div :if={@selected_grants != []} class="divide-y divide-black/[0.06]">
        <div :for={grant <- @selected_grants} class="py-3 flex items-start justify-between gap-4">
          <div class="min-w-0">
            <div class="flex items-center gap-2">
              <span class={[
                "h-2 w-2 rounded-full",
                grant_expiry_dot_class(grant)
              ]} />
              <p class="font-mono text-[0.78rem] font-semibold text-black">
                {grant.resource_type}:{grant.resource_id}
              </p>
            </div>
            <p class="font-mono text-[0.68rem] text-black/55 mt-0.5">
              owner={grant.owner_type}:{grant.owner_id || "nil"} · status={grant.status}
            </p>
            <p class="font-mono text-[0.68rem] text-black/45 mt-0.5">
              next refresh: {next_refresh_label(@selected_connect_refresh_schedule, grant)}
            </p>
            <p class="font-mono text-[0.68rem] text-black/45 mt-0.5">
              scopes: {format_grant_scopes(grant.scopes)}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <p class="font-mono text-[0.68rem] text-black/45">
              expires: {if grant.expires_at, do: format_grant_datetime(grant.expires_at), else: "none"}
            </p>
            <button
              :if={grant.refresh_token}
              type="button"
              phx-click="trigger_connect_grant_refresh"
              phx-value-id={grant.id}
              class="font-mono text-[0.68rem] px-2.5 py-1 rounded-lg border border-black/10 text-black/70 hover:bg-black/[0.04]"
            >
              Refresh now
            </button>
            <button
              type="button"
              phx-click="delete_connect_grant"
              phx-value-id={grant.id}
              class="font-mono text-[0.68rem] px-2.5 py-1 rounded-lg border border-red-200 text-red-600 hover:bg-red-50"
            >
              Erase
            </button>
          </div>
        </div>
      </div>
    </BOModal.form_dialog>

    <BOModal.form_dialog
      :if={@credential_modal}
      id="edit-connect-credential-modal"
      cancel_event="close_connect_credential_modal"
      title="Edit Credential"
      max_width_class="max-w-lg"
    >
      <ConnectCredentialForm.credential_form
        :if={@credential_form}
        form={@credential_form}
        changeset={@credential_changeset}
        errors={@credential_errors}
        submit_event="save_connect_credential"
        change_event="validate_connect_credential"
        cancel_event="close_connect_credential_modal"
        id_prefix="edit-connect-credential"
        submit_label="Save"
      />
    </BOModal.form_dialog>
    """
  end

  defp grant_expiry_dot_class(grant) do
    cond do
      is_nil(grant.expires_at) -> "bg-black/25"
      DateTime.compare(grant.expires_at, DateTime.utc_now()) == :lt -> "bg-red-500"
      true -> "bg-emerald-500"
    end
  end

  defp next_refresh_label(refresh_schedule, grant) do
    if grant.refresh_token do
      case Map.get(refresh_schedule, grant.id) do
        %DateTime{} = dt -> format_grant_datetime(dt)
        _ -> "none"
      end
    else
      "n/a"
    end
  end

  defp format_grant_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%SZ")

  defp format_grant_scopes(scopes) when is_list(scopes) do
    case Enum.reject(scopes, &(&1 in [nil, ""])) do
      [] -> "none"
      values -> Enum.join(values, ", ")
    end
  end

  defp format_grant_scopes(_), do: "none"
end
