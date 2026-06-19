defmodule Storybook.Components.Icons.McpEndpointIcons do
  use PhoenixStorybook.Story, :page

  def description, do: "MCP (Model Context Protocol) endpoint provider icons."

  @endpoints ~w(github_mcp stripe_mcp context_awesome_mcp datagouv_mcp tweetsave_mcp)

  def render(assigns) do
    assigns = assign(assigns, :endpoints, @endpoints)

    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem;">
      <p style="font-size: 0.75rem; opacity: 0.5; font-family: ui-monospace, monospace; margin-bottom: 1.5rem;">
        &lt;ZaqWeb.Components.MCPEndpointIcons.icon provider="github_mcp" class="w-6 h-6" /&gt;
      </p>
      <div style="display: flex; flex-wrap: wrap; gap: 1.5rem;">
        <div
          :for={endpoint <- @endpoints}
          style="display: flex; flex-direction: column; align-items: center; gap: 0.5rem; width: 96px;"
        >
          <div style="width: 48px; height: 48px; display: flex; align-items: center; justify-content: center; background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 10px;">
            <ZaqWeb.Components.MCPEndpointIcons.icon provider={endpoint} class="w-6 h-6" />
          </div>
          <span style="font-family: ui-monospace, monospace; font-size: 0.6rem; opacity: 0.5; text-align: center; word-break: break-word;">
            {endpoint}
          </span>
        </div>
      </div>
    </div>
    """
  end
end
