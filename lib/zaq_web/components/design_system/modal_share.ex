defmodule ZaqWeb.Components.DesignSystem.ModalShare do
  @moduledoc """
  BO ingestion share / permissions modal (people, teams, public toggle).
  """

  use Phoenix.Component

  import ZaqWeb.Components.SearchableSelect

  attr :modal_name, :string, required: true
  attr :modal_error, :string, default: nil
  attr :share_modal_is_folder, :boolean, default: false
  attr :share_modal_is_public, :boolean, default: false
  attr :share_modal_original_is_public, :boolean, default: false
  attr :share_modal_permissions, :list, required: true
  attr :share_modal_targets_options, :list, required: true
  attr :share_modal_pending, :list, required: true
  attr :share_modal_read_only, :boolean, default: false
  attr :share_modal_notice, :string, default: nil

  def modal_share(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/30 backdrop-blur-sm">
      <div class="bg-white rounded-2xl shadow-xl border border-black/[0.06] w-full max-w-lg mx-4 flex flex-col max-h-[90vh]">
        <%!-- Header --%>
        <div class="px-6 py-5 border-b border-black/[0.06] bg-[#fafafa] rounded-t-2xl flex items-center justify-between shrink-0">
          <div>
            <h3 class="font-mono text-[0.9rem] font-bold text-black">Share with People & Teams</h3>
            <p class="font-mono text-[0.72rem] text-black/40 mt-0.5 truncate max-w-xs">
              {@modal_name}
            </p>
            <p
              :if={@share_modal_is_folder}
              class="font-mono text-[0.68rem] zaq-text-accent mt-0.5"
            >
              Permissions will apply to all documents inside this folder
            </p>
            <p
              :if={@share_modal_read_only}
              class="font-mono text-[0.68rem] zaq-text-accent mt-0.5"
            >
              Review imported access
            </p>
          </div>
          <button
            phx-click="close_modal"
            class="p-1.5 hover:bg-black/5 rounded-lg text-black/30 hover:text-black/60 transition-colors cursor-pointer"
          >
            <svg
              class="w-4 h-4"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <%!-- Scrollable: existing permissions + pending list --%>
        <div class="px-6 py-5 space-y-4 overflow-y-auto max-h-[40vh]">
          <div
            :if={@share_modal_notice}
            class="px-3 py-3 rounded-xl border border-[var(--zaq-color-accent-border)] zaq-bg-accent-faint"
          >
            <p class="font-mono text-[0.72rem] zaq-text-accent">
              {@share_modal_notice}
            </p>
          </div>

          <%!-- Public access toggle --%>
          <div
            :if={not @share_modal_read_only}
            class="flex items-center justify-between gap-3 px-3 py-3 rounded-xl border border-black/10 bg-[#fafafa]"
            data-testid="public-toggle"
          >
            <div class="flex items-center gap-2.5 min-w-0">
              <svg
                class="w-4 h-4 text-black/40 shrink-0"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <circle cx="12" cy="12" r="10" />
                <path
                  stroke-linecap="round"
                  d="M2 12h20M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z"
                />
              </svg>
              <div>
                <p class="font-mono text-[0.82rem] text-black/80">Public access</p>
                <p class="font-mono text-[0.68rem] text-black/40">
                  <%= if @share_modal_is_folder do %>
                    All files in this folder are visible to everyone
                  <% else %>
                    Anyone can view this document
                  <% end %>
                </p>
              </div>
            </div>
            <button
              phx-click="toggle_public"
              class={[
                "relative inline-flex h-5 w-9 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 focus:outline-none",
                if(@share_modal_is_public, do: "bg-[var(--zaq-color-accent)]", else: "bg-black/20")
              ]}
              role="switch"
              aria-checked={to_string(@share_modal_is_public)}
            >
              <span class={[
                "pointer-events-none inline-block h-4 w-4 rounded-full bg-white shadow transform transition-transform duration-200",
                if(@share_modal_is_public, do: "translate-x-4", else: "translate-x-0")
              ]} />
            </button>
          </div>
          <%!-- Existing permissions --%>
          <div :if={@share_modal_permissions != []}>
            <p class="font-mono text-[0.72rem] text-black/40 mb-2 uppercase tracking-wide">
              Current permissions
            </p>
            <div class="space-y-2">
              <div
                :for={perm <- @share_modal_permissions}
                class="flex items-center justify-between gap-3 px-3 py-2 rounded-xl border border-black/10 bg-[#fafafa]"
              >
                <div class="flex-1 min-w-0">
                  <span class="font-mono text-[0.82rem] text-black/80 truncate block">
                    {if perm.person,
                      do: "#{perm.person.full_name} (#{perm.person.email})",
                      else: "team: #{perm.team && perm.team.name}"}
                  </span>
                  <div class="flex gap-1 mt-1">
                    <span
                      :for={right <- perm.access_rights}
                      class="font-mono text-[0.65rem] px-1.5 py-0.5 rounded zaq-bg-accent-soft zaq-text-accent"
                    >
                      {right}
                    </span>
                  </div>
                </div>
                <button
                  :if={not @share_modal_read_only}
                  phx-click="remove_permission"
                  phx-value-id={perm.id}
                  class="text-black/20 hover:text-red-400 transition-colors shrink-0"
                >
                  <svg
                    class="w-4 h-4"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    viewBox="0 0 24 24"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
                  </svg>
                </button>
              </div>
            </div>
          </div>

          <%!-- Pending list --%>
          <div :if={not @share_modal_read_only and @share_modal_pending != []}>
            <p class="font-mono text-[0.72rem] text-black/40 mb-2 uppercase tracking-wide">
              To be added
            </p>
            <div class="space-y-3">
              <div
                :for={{entry, idx} <- Enum.with_index(@share_modal_pending)}
                class="px-3 py-3 rounded-xl border border-[var(--zaq-color-accent)] zaq-bg-accent-faint"
              >
                <div class="flex items-center justify-between mb-2">
                  <span class="font-mono text-[0.82rem] text-black/80 truncate">{entry.name}</span>
                  <button
                    phx-click="remove_pending"
                    phx-value-index={idx}
                    class="text-black/20 hover:text-red-400 transition-colors"
                  >
                    <svg
                      class="w-3.5 h-3.5"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      viewBox="0 0 24 24"
                    >
                      <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
                    </svg>
                  </button>
                </div>
                <div class="flex flex-wrap gap-1.5">
                  <label
                    :for={right <- ~w(read write update delete)}
                    class={[
                      "flex items-center gap-1.5 px-2 py-1 rounded-lg border cursor-pointer transition-all select-none text-[0.72rem] font-mono",
                      if(right in entry.access_rights,
                        do: "border-[var(--zaq-color-accent)] zaq-bg-accent-soft zaq-text-accent",
                        else: "border-black/10 bg-white text-black/40 hover:border-black/20"
                      )
                    ]}
                  >
                    <input
                      type="checkbox"
                      checked={right in entry.access_rights}
                      phx-click="toggle_permission_right"
                      phx-value-index={idx}
                      phx-value-right={right}
                      class="hidden"
                    />
                    {right}
                  </label>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Add target — outside scroll so dropdown overflows freely --%>
        <div :if={not @share_modal_read_only} class="px-6 pb-4 shrink-0">
          <p class="font-mono text-[0.72rem] text-black/40 mb-2 uppercase tracking-wide">
            Add person or team
          </p>
          <form phx-change="add_permission_target">
            <.searchable_select
              id="share-target-select"
              name="value"
              value=""
              options={@share_modal_targets_options}
              placeholder="Search people or teams…"
              empty_label="No matches"
            />
          </form>
          <p :if={@modal_error} class="font-mono text-[0.72rem] text-red-500 mt-2">{@modal_error}</p>
        </div>

        <%!-- Footer --%>
        <div class="px-6 py-4 bg-[#fafafa] border-t border-black/[0.06] rounded-b-2xl flex items-center justify-end gap-2 shrink-0">
          <button
            phx-click="close_modal"
            class="font-mono text-[0.78rem] px-4 py-2 rounded-xl text-black/50 hover:bg-black/5 transition-colors"
          >
            Cancel
          </button>
          <button
            :if={not @share_modal_read_only}
            phx-click="confirm_share"
            class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-[var(--zaq-color-accent)] text-white hover:bg-[var(--zaq-color-accent-hover)] shadow-sm shadow-[var(--zaq-color-accent-border)] transition-all disabled:opacity-40"
            disabled={
              @share_modal_pending == [] and @share_modal_is_public == @share_modal_original_is_public
            }
          >
            Save Permissions
          </button>
        </div>
      </div>
    </div>
    """
  end
end
