defmodule ZaqWeb.Live.BO.System.SystemConfig.AICredentialsTab do
  @moduledoc """
  Tab component for the BO system configuration page.
  """
  use ZaqWeb, :html
  import ZaqWeb.Components.SearchableSelect
  alias Phoenix.LiveView.JS
  alias ZaqWeb.Components.BOModal
  alias ZaqWeb.Components.DesignSystem.Button

  attr :credentials, :list, required: true
  attr :ai_grants, :list, default: []
  attr :form, :any, required: true
  attr :modal, :boolean, required: true
  attr :delete_confirm_modal, :boolean, default: false
  attr :action, :atom, required: true
  attr :credential_id, :any, default: nil
  attr :provider_options, :list, required: true

  def panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa] flex items-center justify-between">
        <div>
          <h2 class="font-mono text-[0.95rem] font-bold text-black">AI Credentials</h2>
          <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
            Reusable AI provider credentials used by LLM, Embedding, and Image to Text.
          </p>
        </div>
        <button
          type="button"
          phx-click="new_ai_credential"
          class="font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg bg-[#03b6d4] text-white hover:bg-[#029ab3] transition-all"
        >
          + New credential
        </button>
      </div>

      <div :if={@credentials == []} class="px-8 py-10 text-center">
        <p class="font-mono text-[0.85rem] text-black/50">No AI credentials configured yet.</p>
      </div>

      <div :if={@credentials != []} class="divide-y divide-black/[0.06]">
        <button
          :for={credential <- @credentials}
          type="button"
          phx-click="edit_ai_credential"
          phx-value-id={credential.id}
          class="w-full text-left px-8 py-4 hover:bg-black/[0.02] transition-all"
        >
          <div class="flex items-center justify-between gap-4">
            <div>
              <p class="font-mono text-[0.82rem] font-semibold text-black">{credential.name}</p>
              <p class="font-mono text-[0.7rem] text-black/50 mt-0.5">
                {credential.provider}
              </p>
              <div class="mt-2 flex flex-wrap items-center gap-2">
                <span class="font-mono text-[0.64rem] px-2 py-1 rounded border border-black/10 bg-black/[0.03] text-black/55">
                  {auth_mode_label(credential)}
                </span>
                <% {status_label, status_class} = bearer_status(credential, @ai_grants) %>
                <span class={["font-mono text-[0.64rem] px-2 py-1 rounded border", status_class]}>
                  {status_label}
                </span>
              </div>
              <p :if={credential.description} class="font-mono text-[0.7rem] text-black/35 mt-0.5">
                {credential.description}
              </p>
            </div>
            <span class={[
              "font-mono text-[0.64rem] px-2 py-1 rounded border",
              if(credential.sovereign,
                do: "text-emerald-700 bg-emerald-50 border-emerald-200",
                else: "text-black/60 bg-black/[0.03] border-black/10"
              )
            ]}>
              {if credential.sovereign, do: "Sovereign", else: "Non-sovereign"}
            </span>
          </div>
        </button>
      </div>
    </div>

    <BOModal.form_dialog
      :if={@modal}
      id="ai-credential-modal"
      cancel_event="close_ai_credential_modal"
      title={if @action == :edit, do: "Edit AI Credential", else: "New AI Credential"}
      max_width_class="max-w-2xl"
    >
      <.form
        id="ai-credential-form"
        for={@form}
        phx-change="validate_ai_credential"
        phx-submit="save_ai_credential"
        class="space-y-4"
      >
        <p
          :for={{msg, opts} <- Keyword.get_values(@form.errors, :base)}
          class="font-mono text-[0.72rem] text-red-500 bg-red-50 border border-red-100 rounded-xl px-3 py-2"
        >
          {translate_error({msg, opts})}
        </p>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Name
            </label>
            <input
              type="text"
              name="ai_credential[name]"
              value={@form[:name].value}
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            />
            <p
              :for={{msg, opts} <- @form[:name].errors}
              class="font-mono text-[0.72rem] text-red-500 mt-1.5"
            >
              {translate_error({msg, opts})}
            </p>
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Provider
            </label>
            <.searchable_select
              id="ai-credential-provider-select"
              name="ai_credential[provider]"
              value={@form[:provider].value}
              options={@provider_options}
              placeholder="Search providers..."
              empty_label="Select a provider..."
            />
            <p
              :for={{msg, opts} <- @form[:provider].errors}
              class="font-mono text-[0.72rem] text-red-500 mt-1.5"
            >
              {translate_error({msg, opts})}
            </p>
          </div>
        </div>

        <div>
          <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
            Endpoint URL
          </label>
          <input
            type="text"
            name="ai_credential[endpoint]"
            value={@form[:endpoint].value}
            class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
          />
          <p
            :for={{msg, opts} <- @form[:endpoint].errors}
            class="font-mono text-[0.72rem] text-red-500 mt-1.5"
          >
            {translate_error({msg, opts})}
          </p>
        </div>

        <div>
          <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
            Auth mode
          </label>
          <input
            :if={oauth_only_provider?(@form)}
            type="hidden"
            name="ai_credential[auth_mode]"
            value="oauth2"
          />
          <select
            name="ai_credential[auth_mode]"
            disabled={oauth_only_provider?(@form)}
            class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
          >
            <option
              :if={not oauth_only_provider?(@form)}
              value="api_key"
              selected={auth_mode(@form) == "api_key"}
            >
              API key
            </option>
            <option value="oauth2" selected={auth_mode(@form) == "oauth2"}>OAuth2</option>
          </select>
          <p class="font-mono text-[0.7rem] text-black/40 mt-1.5">
            <%= if oauth_only_provider?(@form) do %>
              OpenAI Codex uses ChatGPT subscription OAuth2 and does not accept API keys.
            <% else %>
              API keys are preferred when present. OAuth2 uses Connect grants bound to this AI credential.
            <% end %>
          </p>
        </div>

        <div :if={not oauth_only_provider?(@form)}>
          <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
            API Key
          </label>
          <div class="relative">
            <input
              type="text"
              id="ai-credential-api-key-input"
              name="ai_credential[api_key]"
              value={@form[:api_key].value}
              autocomplete="off"
              style="-webkit-text-security: disc;"
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 pr-10 bg-[#fafafa]"
            />
            <button
              type="button"
              id="ai-credential-api-key-show"
              phx-click={
                JS.remove_attribute("style", to: "#ai-credential-api-key-input")
                |> JS.add_class("hidden", to: "#ai-credential-api-key-show")
                |> JS.remove_class("hidden", to: "#ai-credential-api-key-hide")
              }
              class="absolute inset-y-0 right-0 flex items-center px-3 text-black/30 hover:text-black/60 transition-colors"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
                class="w-4 h-4"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z"
                /><path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
                />
              </svg>
            </button>
            <button
              type="button"
              id="ai-credential-api-key-hide"
              phx-click={
                JS.set_attribute({"style", "-webkit-text-security: disc;"},
                  to: "#ai-credential-api-key-input"
                )
                |> JS.remove_class("hidden", to: "#ai-credential-api-key-show")
                |> JS.add_class("hidden", to: "#ai-credential-api-key-hide")
              }
              class="hidden absolute inset-y-0 right-0 flex items-center px-3 text-black/30 hover:text-black/60 transition-colors"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                stroke-width="1.5"
                stroke="currentColor"
                class="w-4 h-4"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M3.98 8.223A10.477 10.477 0 0 0 1.934 12C3.226 16.338 7.244 19.5 12 19.5c.993 0 1.953-.138 2.863-.395M6.228 6.228A10.451 10.451 0 0 1 12 4.5c4.756 0 8.773 3.162 10.065 7.498a10.522 10.522 0 0 1-4.293 5.774M6.228 6.228 3 3m3.228 3.228 3.65 3.65m7.894 7.894L21 21m-3.228-3.228-3.65-3.65m0 0a3 3 0 1 0-4.243-4.243m4.242 4.242L9.88 9.88"
                />
              </svg>
            </button>
          </div>
          <p
            :for={{msg, opts} <- @form[:api_key].errors}
            class="font-mono text-[0.72rem] text-red-500 mt-1.5"
          >
            {translate_error({msg, opts})}
          </p>
          <p
            :if={auth_mode(@form) != "api_key"}
            class="font-mono text-[0.7rem] text-amber-700 bg-amber-50 border border-amber-100 rounded-xl px-3 py-2 mt-2"
          >
            Leave the API key blank to use the OAuth2 bearer token. If an API key is saved here, it will remain preferred.
          </p>
        </div>

        <div>
          <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
            Metadata JSON
          </label>
          <textarea
            name="ai_credential[metadata]"
            rows="5"
            class="w-full font-mono text-[0.78rem] text-black border border-black/10 rounded-xl px-4 py-3 bg-[#fafafa]"
          >{metadata_json(@form[:metadata].value)}</textarea>
          <p
            :for={{msg, opts} <- @form[:metadata].errors}
            class="font-mono text-[0.72rem] text-red-500 mt-1.5"
          >
            {translate_error({msg, opts})}
          </p>
          <p
            :if={auth_mode(@form) == "oauth2"}
            class="font-mono text-[0.7rem] text-black/45 mt-1.5"
          >
            Include provider-specific OAuth2 metadata. OpenAI Codex credentials seed the ChatGPT Codex OAuth and backend defaults.
          </p>
        </div>

        <div>
          <label class="flex items-center gap-3 cursor-pointer">
            <input
              type="hidden"
              name="ai_credential[sovereign]"
              value="false"
            />
            <input
              type="checkbox"
              name="ai_credential[sovereign]"
              value="true"
              checked={@form[:sovereign].value in [true, "true"]}
              class="sr-only peer"
            />
            <div class="w-11 h-6 bg-black/10 peer-checked:bg-[#03b6d4] rounded-full transition-colors after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5 after:shadow-sm relative">
            </div>
            <span class="font-mono text-[0.78rem] text-black/70">Sovereign credential</span>
          </label>
        </div>

        <div>
          <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
            Description
          </label>
          <textarea
            name="ai_credential[description]"
            rows="3"
            class="w-full font-mono text-[0.84rem] text-black border border-black/10 rounded-xl px-4 py-3 bg-[#fafafa]"
          >{@form[:description].value}</textarea>
        </div>
      </.form>

      <:actions>
        <div class="flex w-full items-center justify-between gap-3">
          <Button.button
            :if={@action == :edit}
            variant={:tertiary}
            danger
            phx-click="open_delete_ai_credential_confirm"
          >
            Delete credential
          </Button.button>

          <div class="ml-auto flex items-center gap-3">
            <Button.button
              :if={@action == :edit and auth_mode(@form) == "oauth2"}
              variant={:secondary}
              type="button"
              phx-click="connect_ai_credential_oauth"
              phx-value-id={@credential_id}
            >
              Connect OAuth2
            </Button.button>
            <Button.button variant={:secondary} phx-click="close_ai_credential_modal">
              Cancel
            </Button.button>
            <Button.button type="submit" form="ai-credential-form">
              Save credential
            </Button.button>
          </div>
        </div>
      </:actions>

      <BOModal.confirm_dialog
        :if={@delete_confirm_modal}
        id="ai-credential-delete-confirm"
        cancel_event="cancel_delete_ai_credential"
        confirm_event="confirm_delete_ai_credential"
        title="Delete AI Credential?"
        message="This action removes the credential. Deletion is blocked if the credential is currently in use."
        confirm_label="Delete"
        cancel_label="Cancel"
      />
    </BOModal.form_dialog>
    """
  end

  defp auth_mode(form) do
    metadata = form[:metadata].value
    auth_kind = metadata_value(metadata, "auth_kind")
    auth_profile = metadata_value(metadata, "auth_profile")

    case {form[:provider].value, auth_kind} do
      {"openai_codex", _} -> "oauth2"
      {_, "oauth2"} -> "oauth2"
      _ -> if(auth_profile == "openai_chatgpt_codex", do: "oauth2", else: "api_key")
    end
  end

  defp oauth_only_provider?(form), do: form[:provider].value == "openai_codex"

  defp auth_mode_label(%{provider: "openai_codex"}), do: "OAuth2"

  defp auth_mode_label(%{api_key: api_key}) when is_binary(api_key) and api_key != "",
    do: "API key"

  defp auth_mode_label(%{metadata: metadata}) do
    case metadata_value(metadata, "auth_kind") do
      "oauth2" ->
        "OAuth2"

      _ ->
        if metadata_value(metadata, "auth_profile") == "openai_chatgpt_codex" do
          "OAuth2"
        else
          "API key"
        end
    end
  end

  defp bearer_status(%{provider: "openai_codex"} = credential, grants),
    do: bearer_grant_status(credential, grants)

  defp bearer_status(%{api_key: api_key}, _grants) when is_binary(api_key) and api_key != "" do
    {"API key configured", "text-emerald-700 bg-emerald-50 border-emerald-200"}
  end

  defp bearer_status(credential, grants), do: bearer_grant_status(credential, grants)

  defp bearer_grant_status(%{id: id}, grants) do
    grant =
      Enum.find(grants, fn grant ->
        grant.resource_type == "ai_provider_credential" and
          to_string(grant.resource_id) == to_string(id)
      end)

    cond do
      is_nil(grant) ->
        {"No bearer grant", "text-amber-700 bg-amber-50 border-amber-200"}

      grant.status != "active" ->
        {"Grant #{grant.status}", "text-red-700 bg-red-50 border-red-200"}

      expired?(grant.expires_at) ->
        {"Grant expired", "text-red-700 bg-red-50 border-red-200"}

      is_nil(grant.expires_at) ->
        {"Bearer grant active", "text-emerald-700 bg-emerald-50 border-emerald-200"}

      true ->
        {"Bearer until #{Calendar.strftime(grant.expires_at, "%Y-%m-%d %H:%M")}",
         "text-emerald-700 bg-emerald-50 border-emerald-200"}
    end
  end

  defp metadata_json(metadata) when is_map(metadata) do
    Jason.encode!(metadata, pretty: true)
  end

  defp metadata_json(metadata) when is_binary(metadata), do: metadata
  defp metadata_json(_), do: "{}"

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, String.to_existing_atom(key))

  defp metadata_value(_, _), do: nil

  defp expired?(nil), do: false
  defp expired?(expires_at), do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt
end
