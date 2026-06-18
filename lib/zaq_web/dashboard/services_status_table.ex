defmodule ZaqWeb.Dashboard.ServicesStatusTable do
  @moduledoc """
  BO main dashboard — cluster services health table (name, description, node, status).
  """

  use Phoenix.Component

  attr :services, :list, required: true

  def services_status_table(assigns) do
    ~H"""
    <div class="col-span-2">
      <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-3">Services</p>
      <div class="bg-white rounded-xl border border-black/10 overflow-hidden">
        <table class="w-full">
          <thead>
            <tr class="border-b border-black/10">
              <th class="text-left font-mono text-[0.7rem] text-black/40 uppercase tracking-wider px-6 py-3">
                Service
              </th>
              <th class="text-left font-mono text-[0.7rem] text-black/40 uppercase tracking-wider px-6 py-3">
                Description
              </th>
              <th class="text-left font-mono text-[0.7rem] text-black/40 uppercase tracking-wider px-6 py-3">
                Node
              </th>
              <th class="text-right font-mono text-[0.7rem] text-black/40 uppercase tracking-wider px-6 py-3">
                Status
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={svc <- @services}
              class="border-b border-black/5 last:border-0 hover:bg-black/[0.02]"
            >
              <td class="font-mono text-sm font-bold text-black px-6 py-4">{svc.name}</td>
              <td class="font-mono text-[0.75rem] text-black/50 px-6 py-4">{svc.description}</td>
              <td class="font-mono text-[0.7rem] text-black/40 px-6 py-4">
                <%= if svc.node do %>
                  {svc.node}
                <% else %>
                  —
                <% end %>
              </td>
              <td class="px-6 py-4 text-right">
                <span
                  :if={svc.active}
                  class="font-mono text-[0.7rem] px-2 py-1 rounded bg-emerald-100 text-emerald-700"
                >
                  Running
                </span>
                <span
                  :if={!svc.active}
                  class="font-mono text-[0.7rem] px-2 py-1 rounded bg-black/5 text-black/30"
                >
                  Disabled
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
