defmodule Storybook.Components.SearchableSelect do
  use PhoenixStorybook.Story, :page

  def description, do: "Dropdown with search filtering. Supports static options and allow-create."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 2rem; max-width: 360px;">

      <.variation label="No selection">
        <ZaqWeb.Components.SearchableSelect.searchable_select
          id="select-empty"
          name="channel"
          placeholder="Select a channel…"
          options={[{"Slack", "slack"}, {"Microsoft Teams", "teams"}, {"Discord", "discord"}]}
        />
      </.variation>

      <.variation label="Pre-selected value">
        <ZaqWeb.Components.SearchableSelect.searchable_select
          id="select-value"
          name="channel"
          value="slack"
          options={[{"Slack", "slack"}, {"Microsoft Teams", "teams"}, {"Discord", "discord"}]}
        />
      </.variation>

      <.variation label="Compact">
        <ZaqWeb.Components.SearchableSelect.searchable_select
          id="select-compact"
          name="role"
          compact={true}
          placeholder="Role…"
          options={[{"Admin", "admin"}, {"Editor", "editor"}, {"Viewer", "viewer"}]}
        />
      </.variation>

      <.variation label="Allow create">
        <ZaqWeb.Components.SearchableSelect.searchable_select
          id="select-create"
          name="tag"
          allow_create={true}
          placeholder="Add or select a tag…"
          options={[{"Elixir", "elixir"}, {"Phoenix", "phoenix"}]}
        />
      </.variation>

    </div>
    """
  end

  defp variation(assigns) do
    ~H"""
    <div style="display: flex; flex-direction: column; gap: 0.4rem;">
      <span style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase; opacity: 0.4;"><%= @label %></span>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end
end
