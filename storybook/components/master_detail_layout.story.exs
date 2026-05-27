defmodule Storybook.Components.MasterDetailLayout do
  use PhoenixStorybook.Story, :page

  def description, do: "Responsive split-view layout: master list on the left, detail panel on the right."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 3rem;">

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">With detail panel open</h2>
        <div style="border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 8px; overflow: hidden; height: 320px;">
          <ZaqWeb.Components.MasterDetailLayout.master_detail show_detail={true}>
            <:master>
              <div style="padding: 1rem; display: flex; flex-direction: column; gap: 0.5rem; height: 100%; overflow-y: auto;">
                <div :for={item <- ["Knowledge base", "Team handbook", "Onboarding guide", "API reference"]}
                     style="padding: 0.75rem 1rem; border-radius: 6px; font-size: 0.85rem; cursor: pointer; background: rgba(0,0,0,0.02);">
                  <%= item %>
                </div>
              </div>
            </:master>
            <:detail>
              <div style="padding: 1.5rem; height: 100%;">
                <h3 style="font-size: 1rem; font-weight: 600; margin-bottom: 0.5rem;">Knowledge base</h3>
                <p style="font-size: 0.85rem; opacity: 0.6; line-height: 1.6;">
                  The main knowledge repository for your organisation. Documents indexed here are available to the ZAQ assistant.
                </p>
              </div>
            </:detail>
          </ZaqWeb.Components.MasterDetailLayout.master_detail>
        </div>
      </section>

      <section>
        <h2 style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; opacity: 0.45; margin-bottom: 1rem;">Master only (no detail selected)</h2>
        <div style="border: 1px solid var(--zaq-color-surface-border, #e8e6e1); border-radius: 8px; overflow: hidden; height: 280px;">
          <ZaqWeb.Components.MasterDetailLayout.master_detail show_detail={false}>
            <:master>
              <div style="padding: 1rem; display: flex; flex-direction: column; gap: 0.5rem; height: 100%; overflow-y: auto;">
                <div :for={item <- ["Knowledge base", "Team handbook", "Onboarding guide"]}
                     style="padding: 0.75rem 1rem; border-radius: 6px; font-size: 0.85rem; cursor: pointer; background: rgba(0,0,0,0.02);">
                  <%= item %>
                </div>
              </div>
            </:master>
            <:detail>
              <div style="padding: 1.5rem; display: flex; align-items: center; justify-content: center; height: 100%; opacity: 0.4; font-size: 0.85rem;">
                Select an item to view details
              </div>
            </:detail>
          </ZaqWeb.Components.MasterDetailLayout.master_detail>
        </div>
      </section>

    </div>
    """
  end
end
