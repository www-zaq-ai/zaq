defmodule ZaqWeb.Components.ConnectCredentialForm do
  @moduledoc """
  Reusable form for creating and editing Connect auth credentials.

  This component is shared by BO pages that manage credentials for
  data sources and system configuration.
  """

  use ZaqWeb, :html

  attr :form, :any, required: true
  attr :changeset, :any, required: true
  attr :errors, :list, default: []
  attr :submit_event, :string, required: true
  attr :change_event, :string, required: true
  attr :cancel_event, :string, required: true
  attr :id_prefix, :string, default: "connect-credential"
  attr :submit_label, :string, default: "Create"

  def credential_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="connect-credential-form"
      phx-submit={@submit_event}
      phx-change={@change_event}
      class="space-y-4"
    >
      <div>
        <label class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-2 block">
          Name
        </label>
        <input
          type="text"
          name="credential[name]"
          value={@form[:name].value}
          class="w-full h-11 px-4 rounded-xl border border-black/10 bg-[#f5f5f5] text-black placeholder:text-black/30 text-sm font-mono outline-none focus:border-[#03b6d4] transition-colors"
          placeholder="e.g. Google Drive OAuth"
        />
      </div>

      <div>
        <label class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-2 block">
          Provider
        </label>
        <input
          type="text"
          name="credential[provider]"
          value={@form[:provider].value}
          readonly
          class="w-full h-11 px-4 rounded-xl border border-black/10 bg-black/5 text-black/50 text-sm font-mono outline-none"
        />
      </div>

      <div>
        <label class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-2 block">
          Request Format
        </label>
        <input
          type="text"
          name="credential[request_format]"
          value={@form[:request_format].value}
          readonly
          class="w-full h-11 px-4 rounded-xl border border-black/10 bg-black/5 text-black/50 text-sm font-mono outline-none"
        />
      </div>

      <div>
        <label class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-2 block">
          Auth Kind
        </label>
        <select
          name="credential[auth_kind]"
          class="w-full h-11 px-4 rounded-xl border border-black/10 bg-[#f5f5f5] text-black text-sm font-mono outline-none focus:border-[#03b6d4] transition-colors"
        >
          <option value="oauth2" selected={auth_kind(@changeset) == "oauth2"}>oauth2</option>
          <option value="api_key" selected={auth_kind(@changeset) == "api_key"}>api_key</option>
        </select>
      </div>

      <div :if={auth_kind(@changeset) == "oauth2"}>
        <label class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-2 block">
          Client ID
        </label>
        <input
          type="text"
          name="credential[client_id]"
          value={@form[:client_id].value}
          class="w-full h-11 px-4 rounded-xl border border-black/10 bg-[#f5f5f5] text-black text-sm font-mono outline-none focus:border-[#03b6d4] transition-colors"
        />
      </div>

      <div :if={auth_kind(@changeset) == "oauth2"}>
        <label class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-2 block">
          Client Secret
        </label>
        <.secret_input
          id={"#{@id_prefix}-client-secret"}
          name="credential[client_secret]"
          value={@form[:client_secret].value}
          placeholder="••••••••"
          input_class="w-full h-11 px-4 pr-11 rounded-xl border border-black/10 bg-[#f5f5f5] text-black text-sm font-mono outline-none focus:border-[#03b6d4] transition-colors"
          button_class="absolute right-3 top-1/2 -translate-y-1/2 text-black/30 hover:text-black/60 transition-colors focus:outline-none"
        />
      </div>

      <div :if={auth_kind(@changeset) == "api_key"}>
        <label class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-2 block">
          API Key
        </label>
        <.secret_input
          id={"#{@id_prefix}-api-key"}
          name="credential[api_key]"
          value={@form[:api_key].value}
          placeholder="••••••••"
          input_class="w-full h-11 px-4 pr-11 rounded-xl border border-black/10 bg-[#f5f5f5] text-black text-sm font-mono outline-none focus:border-[#03b6d4] transition-colors"
          button_class="absolute right-3 top-1/2 -translate-y-1/2 text-black/30 hover:text-black/60 transition-colors focus:outline-none"
        />
      </div>

      <div :if={@errors != []} class="rounded-xl bg-red-50 border border-red-200 p-3">
        <p
          :for={err <- @errors}
          class="font-mono text-[0.7rem] text-red-600 flex items-center gap-1.5"
        >
          <span class="text-red-400">✗</span> {err}
        </p>
      </div>

      <div class="flex justify-end gap-3 pt-2">
        <button
          type="button"
          phx-click={@cancel_event}
          class="font-mono text-[0.75rem] tracking-wide px-5 py-2.5 rounded-xl border border-black/10 text-black/40 hover:text-black hover:border-black/20 transition-all"
        >
          Cancel
        </button>
        <button
          type="submit"
          class="font-mono text-[0.75rem] tracking-wide px-5 py-2.5 rounded-xl font-bold bg-[#03b6d4] text-white hover:bg-[#03b6d4]/90 transition-all"
        >
          {@submit_label}
        </button>
      </div>
    </.form>
    """
  end

  defp auth_kind(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.get_field(changeset, :auth_kind, "oauth2")
  end

  defp auth_kind(_), do: "oauth2"
end
