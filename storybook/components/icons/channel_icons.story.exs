defmodule Storybook.Components.Icons.ChannelIcons do
  use PhoenixStorybook.Story, :page

  def description, do: "Channel provider icons — one for each supported integration."

  @providers ~w(slack teams discord email google_drive mattermost sharepoint smtp telegram webhook zaq_local ai_agents)

  def render(assigns) do
    assigns = assign(assigns, :providers, @providers)

    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem;">
      <div style="display: flex; flex-wrap: wrap; gap: 1.5rem;">
        <div
          :for={provider <- @providers}
          style="display: flex; flex-direction: column; align-items: center; gap: 0.5rem; width: 80px;"
        >
          <div style="width: 48px; height: 48px; display: flex; align-items: center; justify-content: center; background: var(--zaq-color-surface, #faf9f7); border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 10px;">
            <ZaqWeb.Components.ChannelIcons.icon provider={provider} class="w-6 h-6" />
          </div>
          <span style="font-family: ui-monospace, monospace; font-size: 0.6rem; opacity: 0.5; text-align: center; word-break: break-word;">
            {provider}
          </span>
        </div>
      </div>
    </div>
    """
  end
end
