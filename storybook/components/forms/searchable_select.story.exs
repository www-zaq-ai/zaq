defmodule Storybook.Components.Forms.SearchableSelect do
  use PhoenixStorybook.Story, :page

  def description, do: "Dropdown with search filtering. Supports static options and allow-create."

  def render(assigns) do
    ~H"""
    <div style="font-family: var(--zaq-font-primary, sans-serif); padding: 2rem; display: flex; flex-direction: column; gap: 2rem; max-width: 420px;">
      <.variation label="External label (zaq-field)">
        <ZaqWeb.Components.SearchableSelect.searchable_select
          id="select-labeled"
          name="channel"
          label="Channel"
          placeholder="Select a channel…"
          options={[{"Slack", "slack"}, {"Microsoft Teams", "teams"}, {"Discord", "discord"}]}
        />
      </.variation>

      <.variation label="External label (block)">
        <ZaqWeb.Components.SearchableSelect.searchable_select
          id="select-labeled-block"
          name="channel_block"
          label="Channel"
          label_position="block"
          placeholder="Select a channel…"
          options={[{"Slack", "slack"}, {"Microsoft Teams", "teams"}, {"Discord", "discord"}]}
        />
      </.variation>

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

      <.variation label="Clearable label value">
        <ZaqWeb.Components.SearchableSelect.searchable_select
          id="select-clearable-value"
          name="location"
          value="Paris"
          clearable
          compact
          options={[{"No value", ""}, {"Paris", "Paris"}, {"London", "London"}]}
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

      <.variation label="Compact inline label (toolbar)">
        <ZaqWeb.Components.SearchableSelect.searchable_select
          id="select-compact-inline-team"
          name="team_id"
          label="Team"
          compact={true}
          value="all"
          placeholder="Search team…"
          empty_label="All teams"
          options={[{"All teams", "all"}, {"Platform", "1"}, {"Support", "2"}]}
        />
      </.variation>

      <.variation label="Compact inline — short “All people”, long options">
        <ZaqWeb.Components.SearchableSelect.searchable_select
          id="select-compact-inline-person"
          name="person_id"
          label="Person"
          compact={true}
          value="all"
          placeholder="Search person…"
          empty_label="All people"
          options={[
            {"All people", "all"},
            {"Ada Lovelace", "10"},
            {"Grace Hopper", "11"},
            {"Magnus Hirschfeld", "12"}
          ]}
        />
      </.variation>

      <.variation label="Default inline label — short “All” selection">
        <ZaqWeb.Components.SearchableSelect.searchable_select
          id="select-default-inline-channel"
          name="channel_type"
          label="Channel"
          value="all"
          empty_label="All"
          options={[
            {"All", "all"},
            {"BO", "bo"},
            {"Mattermost", "mattermost"},
            {"Slack", "slack"},
            {"Email", "email:imap"}
          ]}
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
      <span style="font-size: 0.7rem; font-weight: 600; letter-spacing: 0.05em; text-transform: uppercase; opacity: 0.4;">
        {@label}
      </span>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
