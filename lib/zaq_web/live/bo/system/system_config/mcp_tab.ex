defmodule ZaqWeb.Live.BO.System.SystemConfig.MCPTab do
  @moduledoc """
  Tab component for the BO system configuration page.
  """
  use ZaqWeb, :html
  alias Phoenix.LiveView.JS
  alias ZaqWeb.Components.BOModal

  # ── MCP Administration Panel ────────────────────────────────────────────

  attr :entries, :list, required: true
  attr :total_count, :integer, required: true
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :filter_name, :string, required: true
  attr :filter_type, :string, required: true
  attr :filter_status, :string, required: true
  attr :form, :any, required: true
  attr :rows, :map, required: true
  attr :modal, :boolean, required: true
  attr :action, :atom, required: true
  attr :delete_confirm_modal, :boolean, required: true

  def panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa] flex items-center justify-between">
        <div>
          <h2 class="font-mono text-[0.95rem] font-bold text-black">MCP Administration</h2>
          <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
            Manage Model Context Protocol endpoints and test tool loading.
          </p>
        </div>
        <button
          type="button"
          phx-click="new_mcp_endpoint"
          class="font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg bg-[#03b6d4] text-white hover:bg-[#029ab3] transition-all"
        >
          + Add MCP
        </button>
      </div>

      <form
        phx-change="filter_mcp_endpoints"
        class="px-8 py-4 border-b border-black/[0.06] grid grid-cols-3 gap-3"
      >
        <input
          type="text"
          name="mcp_filter_name"
          value={@filter_name}
          phx-debounce="300"
          placeholder="Search by name"
          class="font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
        />
        <select
          name="mcp_filter_type"
          class="font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
        >
          <option value="all" selected={@filter_type == "all"}>All types</option>
          <option value="local" selected={@filter_type == "local"}>Local</option>
          <option value="remote" selected={@filter_type == "remote"}>Remote</option>
        </select>
        <select
          name="mcp_filter_status"
          class="font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
        >
          <option value="all" selected={@filter_status == "all"}>All statuses</option>
          <option value="enabled" selected={@filter_status == "enabled"}>Enabled</option>
          <option value="disabled" selected={@filter_status == "disabled"}>Disabled</option>
        </select>
      </form>

      <div :if={@entries == []} class="px-8 py-10 text-center">
        <p class="font-mono text-[0.85rem] text-black/50">No MCP entries found.</p>
      </div>

      <div :if={@entries != []} class="divide-y divide-black/[0.06]">
        <div :for={entry <- @entries} class="px-8 py-4 flex items-center justify-between gap-4">
          <div class="min-w-0 flex items-start gap-3">
            <div class="mt-0.5 inline-flex h-7 w-7 shrink-0 items-center justify-center overflow-hidden rounded-lg">
              <ZaqWeb.Components.MCPEndpointIcons.icon
                endpoint_key={entry.predefined_id}
                class="h-7 w-7"
              />
            </div>
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <p class="font-mono text-[0.82rem] font-semibold text-black truncate">{entry.name}</p>
                <span class={[
                  "h-2 w-2 rounded-full",
                  if(entry.status == "enabled", do: "bg-emerald-500", else: "bg-red-500")
                ]} />
              </div>
              <p class="font-mono text-[0.7rem] text-black/45 mt-0.5">
                {entry.type}<span :if={entry.predefined?}> · predefined</span>
              </p>
              <p :if={entry.description} class="font-mono text-[0.7rem] text-black/35 mt-0.5 truncate">
                {entry.description}
              </p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button
              :if={not entry.persisted? and entry.predefined?}
              type="button"
              phx-click="enable_predefined_mcp"
              phx-value-predefined_id={entry.predefined_id}
              class="font-mono text-[0.72rem] px-3 py-1.5 rounded-lg border border-black/10 text-black/70 hover:bg-black/[0.04]"
            >
              Enable
              <span :if={entry.auto_enabled} class="ml-1" title="Immediately available">⚡</span>
            </button>
            <button
              :if={entry.persisted?}
              type="button"
              phx-click="edit_mcp_endpoint"
              phx-value-id={entry.id}
              class="font-mono text-[0.72rem] px-3 py-1.5 rounded-lg border border-black/10 text-black/70 hover:bg-black/[0.04]"
            >
              Edit
            </button>
            <.loading_action_button
              :if={entry.persisted?}
              id={"mcp-test-button-#{entry.id}"}
              phx-click="test_mcp_endpoint"
              phx-value-id={entry.id}
              label="Test"
              loading_label="Testing..."
              class="mcp-test-button font-mono text-[0.72rem] px-3 py-1.5 rounded-lg bg-[#03b6d4] text-white hover:bg-[#029ab3]"
            />
          </div>
        </div>
      </div>

      <div
        :if={@total_count > 0}
        class="px-8 py-3 border-t border-black/[0.06] flex items-center justify-between"
      >
        <span class="font-mono text-[0.68rem] text-black/40">
          {@page * @per_page - @per_page + 1}–{min(@page * @per_page, @total_count)} of {@total_count}
        </span>
        <div class="flex gap-1">
          <button
            :if={@page > 1}
            type="button"
            phx-click="change_mcp_page"
            phx-value-page={@page - 1}
            class="font-mono text-[0.7rem] px-3 py-1.5 rounded-lg border border-black/12 text-black/60 hover:bg-black/5"
          >
            ← Prev
          </button>
          <button
            :if={@page * @per_page < @total_count}
            type="button"
            phx-click="change_mcp_page"
            phx-value-page={@page + 1}
            class="font-mono text-[0.7rem] px-3 py-1.5 rounded-lg border border-black/12 text-black/60 hover:bg-black/5"
          >
            Next →
          </button>
        </div>
      </div>
    </div>

    <BOModal.form_dialog
      :if={@modal}
      id="mcp-endpoint-modal"
      cancel_event="close_mcp_endpoint_modal"
      title={if @action == :edit, do: "Edit MCP Endpoint", else: "New MCP Endpoint"}
      max_width_class="max-w-3xl"
    >
      <.form
        id="mcp-endpoint-form"
        for={@form}
        phx-change="validate_mcp_endpoint"
        phx-submit="save_mcp_endpoint"
        class="space-y-4"
      >
        <p
          :for={{msg, opts} <- Keyword.get_values(@form.errors, :base)}
          class="whitespace-pre-line font-mono text-[0.72rem] text-red-500 bg-red-50 border border-red-100 rounded-xl px-3 py-2"
        >
          {translate_error({msg, opts})}
        </p>

        <div class="grid grid-cols-1 gap-4 md:grid-cols-[minmax(0,1fr)_160px_160px]">
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Name
            </label>
            <input
              type="text"
              name="mcp_endpoint[name]"
              value={@form[:name].value}
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            />
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Status
            </label>
            <label class="h-11 px-1 inline-flex items-center gap-3 cursor-pointer">
              <input
                type="hidden"
                name="mcp_endpoint[status]"
                value={if @form[:status].value == "enabled", do: "enabled", else: "disabled"}
              />
              <input
                type="checkbox"
                checked={@form[:status].value == "enabled"}
                class="sr-only peer"
                phx-click={
                  if @form[:status].value == "enabled" do
                    JS.set_attribute({"value", "disabled"},
                      to: "#mcp-endpoint-form input[name='mcp_endpoint[status]']"
                    )
                  else
                    JS.set_attribute({"value", "enabled"},
                      to: "#mcp-endpoint-form input[name='mcp_endpoint[status]']"
                    )
                  end
                  |> JS.dispatch("change", to: "#mcp-endpoint-form")
                }
              />
              <div class="w-11 h-6 bg-black/10 peer-checked:bg-[#03b6d4] rounded-full transition-colors after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-5 after:w-5 after:transition-all peer-checked:after:translate-x-5 after:shadow-sm relative">
              </div>
              <span class="font-mono text-[0.78rem] text-black/70">
                {if @form[:status].value == "enabled", do: "Enabled", else: "Disabled"}
              </span>
            </label>
          </div>
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Timeout (ms)
            </label>
            <input
              type="number"
              min="1"
              name="mcp_endpoint[timeout_ms]"
              value={@form[:timeout_ms].value || 5000}
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            />
          </div>
        </div>

        <input
          type="hidden"
          name="mcp_endpoint[predefined_id]"
          value={@form[:predefined_id].value || ""}
        />

        <div class="grid grid-cols-1 gap-4 md:grid-cols-[160px_minmax(0,1fr)]">
          <div>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Type
            </label>
            <select
              name="mcp_endpoint[type]"
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            >
              <option value="local" selected={@form[:type].value == "local"}>local</option>
              <option value="remote" selected={@form[:type].value == "remote"}>remote</option>
            </select>
          </div>

          <div :if={@form[:type].value == "local"}>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              Command
            </label>
            <input
              type="text"
              name="mcp_endpoint[command]"
              value={@form[:command].value || ""}
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            />
          </div>

          <div :if={@form[:type].value == "remote"}>
            <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
              URL
            </label>
            <input
              type="text"
              name="mcp_endpoint[url]"
              value={@form[:url].value || ""}
              class="w-full font-mono text-[0.88rem] text-black border border-black/10 rounded-xl h-11 px-4 bg-[#fafafa]"
            />
          </div>
        </div>

        <div :if={@form[:type].value == "local"} class="space-y-4">
          <.mcp_args_rows rows={@rows.args} collection="args" label="Args" placeholder="--flag" />

          <.mcp_kv_rows
            rows={@rows.environments}
            collection="environments"
            label="Environments"
            key_placeholder="KEY"
            value_placeholder="value"
          />

          <.mcp_secret_kv_rows
            rows={@rows.secret_environments}
            collection="secret_environments"
            label="Secret environments"
            key_placeholder="SECRET_KEY"
          />
        </div>

        <div :if={@form[:type].value == "remote"} class="space-y-4">
          <.mcp_kv_rows
            rows={@rows.headers}
            collection="headers"
            label="Headers"
            key_placeholder="Header-Name"
            value_placeholder="value"
          />

          <.mcp_secret_kv_rows
            rows={@rows.secret_headers}
            collection="secret_headers"
            label="Secret headers"
            key_placeholder="Authorization"
          />
        </div>

        <div>
          <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
            Settings (JSON)
          </label>
          <textarea
            name="mcp_endpoint[settings_text]"
            rows="4"
            class="w-full font-mono text-[0.84rem] text-black border border-black/10 rounded-xl px-4 py-3 bg-[#fafafa]"
          >{@rows.settings}</textarea>
        </div>
      </.form>

      <:actions>
        <button
          :if={@action == :edit}
          type="button"
          phx-click="open_delete_mcp_endpoint_confirm"
          class="inline-flex items-center gap-2 font-mono text-[0.8rem] px-4 py-2 rounded-lg border border-red-200 text-red-600 hover:bg-red-50"
        >
          <.icon name="hero-trash" class="h-4 w-4" /> Delete endpoint
        </button>
        <button
          type="submit"
          form="mcp-endpoint-form"
          class="font-mono text-[0.8rem] font-bold px-4 py-2 rounded-lg bg-[#03b6d4] text-white hover:bg-[#029ab3]"
        >
          Save endpoint
        </button>
      </:actions>

      <ZaqWeb.Components.BOModal.confirm_dialog
        :if={@delete_confirm_modal}
        id="mcp-endpoint-delete-confirm"
        cancel_event="cancel_delete_mcp_endpoint"
        confirm_event="confirm_delete_mcp_endpoint"
        title="Delete MCP Endpoint?"
        message="This action removes the endpoint. Associated runtime tools will be unsynced from active agents."
        confirm_label="Delete"
        cancel_label="Cancel"
      />
    </BOModal.form_dialog>
    """
  end

  attr :rows, :list, required: true
  attr :collection, :string, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, default: ""

  defp mcp_args_rows(assigns) do
    ~H"""
    <div>
      <div class="mb-2 flex items-center justify-between">
        <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider">
          {@label}
        </label>
        <button
          type="button"
          phx-click="add_mcp_row"
          phx-value-collection={@collection}
          class="font-mono text-[0.68rem] px-2 py-1 rounded border border-black/10 text-black/60 hover:bg-black/[0.04]"
        >
          + Add
        </button>
      </div>
      <div class="space-y-2">
        <div
          :for={{row, idx} <- Enum.with_index(@rows)}
          class="grid grid-cols-[minmax(0,1fr)_auto] items-center gap-2"
        >
          <input
            type="text"
            name={"mcp_endpoint[#{@collection}_rows][#{idx}][value]"}
            value={row["value"]}
            placeholder={@placeholder}
            class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
          />
          <.mcp_row_delete_button collection={@collection} index={idx} />
        </div>
      </div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :collection, :string, required: true
  attr :label, :string, required: true
  attr :key_placeholder, :string, default: "KEY"
  attr :value_placeholder, :string, default: "value"

  defp mcp_kv_rows(assigns) do
    ~H"""
    <div>
      <div class="mb-2 flex items-center justify-between">
        <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider">
          {@label}
        </label>
        <button
          type="button"
          phx-click="add_mcp_row"
          phx-value-collection={@collection}
          class="font-mono text-[0.68rem] px-2 py-1 rounded border border-black/10 text-black/60 hover:bg-black/[0.04]"
        >
          + Add
        </button>
      </div>
      <div class="space-y-2">
        <div
          :for={{row, idx} <- Enum.with_index(@rows)}
          class="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] items-center gap-2"
        >
          <input
            type="text"
            name={"mcp_endpoint[#{@collection}_rows][#{idx}][key]"}
            value={row["key"]}
            placeholder={@key_placeholder}
            class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
          />
          <input
            type="text"
            name={"mcp_endpoint[#{@collection}_rows][#{idx}][value]"}
            value={row["value"]}
            placeholder={@value_placeholder}
            class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
          />
          <.mcp_row_delete_button collection={@collection} index={idx} />
        </div>
      </div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :collection, :string, required: true
  attr :label, :string, required: true
  attr :key_placeholder, :string, default: "KEY"

  defp mcp_secret_kv_rows(assigns) do
    ~H"""
    <div>
      <div class="mb-2 flex items-center justify-between">
        <label class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider">
          {@label}
        </label>
        <button
          type="button"
          phx-click="add_mcp_row"
          phx-value-collection={@collection}
          class="font-mono text-[0.68rem] px-2 py-1 rounded border border-black/10 text-black/60 hover:bg-black/[0.04]"
        >
          + Add
        </button>
      </div>
      <div class="space-y-2">
        <div
          :for={{row, idx} <- Enum.with_index(@rows)}
          class="grid grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] items-center gap-2"
        >
          <input
            type="text"
            name={"mcp_endpoint[#{@collection}_rows][#{idx}][key]"}
            value={row["key"]}
            placeholder={@key_placeholder}
            class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 bg-[#fafafa]"
          />
          <.secret_input
            id={"mcp-#{@collection}-#{idx}"}
            name={"mcp_endpoint[#{@collection}_rows][#{idx}][value]"}
            value={row["value"]}
            input_class="w-full font-mono text-[0.82rem] text-black border border-black/10 rounded-lg h-10 px-3 pr-10 bg-[#fafafa]"
            button_class="absolute right-3 top-1/2 -translate-y-1/2 text-black/30 hover:text-black/60"
            wrapper_class="relative"
          />
          <.mcp_row_delete_button collection={@collection} index={idx} />
        </div>
      </div>
    </div>
    """
  end

  attr :collection, :string, required: true
  attr :index, :integer, required: true

  defp mcp_row_delete_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="remove_mcp_row"
      phx-value-collection={@collection}
      phx-value-index={@index}
      aria-label="Remove row"
      title="Remove row"
      class="inline-flex h-10 w-10 items-center justify-center rounded-lg border border-red-200 text-red-500 hover:bg-red-50 hover:text-red-600"
    >
      <.icon name="hero-trash" class="h-4 w-4" />
    </button>
    """
  end
end
