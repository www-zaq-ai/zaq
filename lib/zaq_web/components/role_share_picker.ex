defmodule ZaqWeb.Components.RoleSharePicker do
  @moduledoc """
  Reusable role-sharing picker component.

  Renders a list of role checkboxes that let users select which roles
  can access a resource. When no roles are selected, the resource is
  private (accessible only to the ingesting user's role).

  ## Usage

      <ZaqWeb.Components.RoleSharePicker.role_share_picker
        roles={@all_roles}
        selected_role_ids={@shared_role_ids}
        toggle_event="toggle_shared_role"
      />
  """

  use Phoenix.Component

  attr :roles, :list, required: true
  attr :selected_role_ids, :list, required: true
  attr :toggle_event, :string, default: "toggle_shared_role"

  def role_share_picker(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-5 py-3 border-b border-black/[0.06] bg-[#fafafa] flex items-center justify-between">
        <div>
          <p class="font-mono text-[0.7rem] font-semibold text-black/60 uppercase tracking-wider">
            Share with Roles
          </p>
          <p class="font-mono text-[0.65rem] text-black/30 mt-0.5">
            {if @selected_role_ids == [],
              do: "Private — only your role can access ingested content",
              else: "Shared with #{length(@selected_role_ids)} role(s)"}
          </p>
        </div>
        <span class={[
          "font-mono text-[0.65rem] px-2 py-0.5 rounded-full",
          if(@selected_role_ids == [],
            do: "bg-black/5 text-black/30",
            else: "bg-[#03b6d4]/10 text-[#03b6d4]"
          )
        ]}>
          {if @selected_role_ids == [], do: "private", else: "shared"}
        </span>
      </div>

      <div class="px-5 py-4">
        <%= if @roles == [] do %>
          <p class="font-mono text-[0.75rem] text-black/30 italic">No roles defined yet.</p>
        <% else %>
          <div class="flex flex-wrap gap-2">
            <label
              :for={role <- @roles}
              class={[
                "flex items-center gap-2 px-3 py-1.5 rounded-xl border cursor-pointer transition-all",
                if(role.id in @selected_role_ids,
                  do: "border-[#03b6d4] bg-[#03b6d4]/5 text-[#03b6d4]",
                  else: "border-black/10 bg-[#fafafa] text-black/50 hover:border-black/20"
                )
              ]}
            >
              <input
                type="checkbox"
                checked={role.id in @selected_role_ids}
                phx-click={@toggle_event}
                phx-value-role_id={role.id}
                class="hidden"
              />
              <span class={[
                "w-1.5 h-1.5 rounded-full",
                if(role.id in @selected_role_ids, do: "bg-[#03b6d4]", else: "bg-black/20")
              ]}>
              </span>
              <span class="font-mono text-[0.78rem] font-medium">{role.name}</span>
            </label>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
