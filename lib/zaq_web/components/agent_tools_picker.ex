defmodule ZaqWeb.Components.AgentToolsPicker do
  @moduledoc """
  Shared BO components for picking agent capabilities — tools from
  `Zaq.Agent.Tools.Registry` and MCP endpoints from `Zaq.Agent.MCP`.

  Used by both the configured-agent form (`ZaqWeb.Live.BO.AI.AgentsLive`) and the
  skill form (`ZaqWeb.Live.BO.AI.SkillsLive`) so the selection UX stays identical
  across pages.

  - `selected_tools_panel/1` renders the selected tools with ghost handling for
    keys no longer registered in code. Emits `"remove_tool"` (`%{"key" => tool_key}`).
  - `selected_mcp_panel/1` renders the selected MCP endpoints with an enabled/disabled
    status dot and a fallback for unknown ids. Emits `"remove_mcp"` (`%{"id" => id}`).

  The host LiveView must handle the emitted events.
  """

  use ZaqWeb, :html

  @doc """
  Renders the panel of selected tools.

  Expects the full registry `tools` list (maps with `:key`, `:label`,
  `:description`) and the `selected_keys` currently chosen. Keys that are no
  longer present in `tools` are rendered as "Removed" ghosts.
  """
  attr :tools, :list, required: true
  attr :selected_keys, :list, required: true

  def selected_tools_panel(assigns) do
    tool_index = Map.new(assigns.tools, &{&1.key, &1})

    selected_tools =
      Enum.map(assigns.selected_keys, fn key ->
        Map.get(tool_index, key) ||
          %{
            key: key,
            label: key,
            description: "This tool has been removed from the system.",
            ghost: true
          }
      end)

    assigns = assign(assigns, :selected_tools, selected_tools)

    ~H"""
    <div class="rounded-lg border border-[#efece6]">
      <div :if={@selected_tools == []} class="px-3 py-2 font-mono text-[0.68rem] text-[#9a958c]">
        No tools selected.
      </div>
      <div :if={@selected_tools != []} class="max-h-44 overflow-y-auto divide-y divide-[#efece6]">
        <div
          :for={tool <- @selected_tools}
          data-selected-tool-key={tool.key}
          class={[
            "flex items-start justify-between gap-3 px-3 py-2",
            if(Map.get(tool, :ghost), do: "bg-red-50 hover:bg-red-100", else: "hover:bg-[#faf8f5]")
          ]}
        >
          <div>
            <p class={[
              "font-mono text-[0.72rem]",
              if(Map.get(tool, :ghost), do: "text-red-600", else: "text-[#3e3b36]")
            ]}>
              {tool.label}
              <span
                :if={Map.get(tool, :ghost)}
                class="ml-1.5 inline-block rounded bg-red-100 px-1 py-px font-mono text-[0.58rem] text-red-600"
              >
                Removed
              </span>
            </p>
            <p class="font-mono text-[0.64rem] text-[#8f8a82]">{tool.description}</p>
          </div>
          <button
            type="button"
            phx-click="remove_tool"
            phx-value-key={tool.key}
            class="w-6 h-6 rounded border border-black/15 text-black/35 hover:bg-black/5"
          >
            <svg
              class="w-3.5 h-3.5 mx-auto"
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
    """
  end

  @doc """
  Renders the panel of selected MCP endpoints.

  Expects the full `mcp_endpoints` list (structs/maps with `:id`, `:name`, `:status`)
  and the `selected_endpoint_ids` currently chosen. Ids not present in `mcp_endpoints`
  render as an "Unknown MCP" fallback.
  """
  attr :mcp_endpoints, :list, required: true
  attr :selected_endpoint_ids, :list, required: true

  def selected_mcp_panel(assigns) do
    endpoint_index = Map.new(assigns.mcp_endpoints, &{&1.id, &1})

    selected_mcp_endpoints =
      Enum.map(assigns.selected_endpoint_ids, fn endpoint_id ->
        Map.get(endpoint_index, endpoint_id) ||
          %{id: endpoint_id, name: "Unknown MCP ##{endpoint_id}", status: "disabled"}
      end)

    assigns = assign(assigns, :selected_mcp_endpoints, selected_mcp_endpoints)

    ~H"""
    <div class="rounded-lg border border-[#efece6]">
      <div
        :if={@selected_mcp_endpoints == []}
        class="px-3 py-2 font-mono text-[0.68rem] text-[#9a958c]"
      >
        No MCP endpoints selected.
      </div>
      <div
        :if={@selected_mcp_endpoints != []}
        class="max-h-44 overflow-y-auto divide-y divide-[#efece6]"
      >
        <div
          :for={endpoint <- @selected_mcp_endpoints}
          data-selected-mcp-endpoint-id={endpoint.id}
          class="flex items-start justify-between gap-3 px-3 py-2 hover:bg-[#faf8f5]"
        >
          <div>
            <p class="flex items-center gap-2 font-mono text-[0.72rem] text-[#3e3b36]">
              <span class={[
                "h-2 w-2 rounded-full",
                if(endpoint.status == "enabled", do: "bg-emerald-500", else: "bg-red-500")
              ]} />
              {endpoint.name}
            </p>
          </div>
          <button
            type="button"
            phx-click="remove_mcp"
            phx-value-id={endpoint.id}
            class="w-6 h-6 rounded border border-black/15 text-black/35 hover:bg-black/5"
          >
            <svg
              class="w-3.5 h-3.5 mx-auto"
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
    """
  end
end
