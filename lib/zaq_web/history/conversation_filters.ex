defmodule ZaqWeb.History.ConversationFilters do
  @moduledoc """
  Toolbar for the BO conversation history page: count, admin scope, team/person
  filters, and channel type.
  """

  use Phoenix.Component

  import ZaqWeb.Components.SearchableSelect
  import ZaqWeb.Select, only: [select: 1]

  alias ZaqWeb.Components.DesignSystem.Toggle, as: DSToggle

  @channel_type_options [
    {"All", "all"},
    {"BO", "bo"},
    {"Mattermost", "mattermost"},
    {"Slack", "slack"},
    {"Email", "email:imap"},
    {"API", "api"}
  ]

  attr :conversation_count, :integer, required: true
  attr :status, :string, required: true, doc: "`active` or `archived` — default route is active."
  attr :is_admin, :boolean, required: true
  attr :filter_scope, :string, required: true
  attr :filter_channel_type, :string, required: true
  attr :filter_team_id, :string, required: true
  attr :filter_person_id, :string, required: true
  attr :teams, :list, required: true
  attr :people, :list, required: true

  def conversation_filters(assigns) do
    assigns =
      assigns
      |> assign(:count_suffix, "#{assigns.conversation_count} conversations")
      |> assign(:channel_type_options, @channel_type_options)

    ~H"""
    <div class="zaq-ingestion-chrome-row zaq-ingestion-chrome-row--spaced">
      <DSToggle.toggle
        :if={@is_admin}
        value={@filter_scope}
        event="filter"
        value_param="scope"
        suffix={@count_suffix}
        choices={[
          %{value: "own", label: "My History"},
          %{value: "all", label: "All Users"}
        ]}
      />
      <span :if={not @is_admin} class="zaq-text-caption zaq-toggle-count">
        {@count_suffix}
      </span>

      <form
        id="conversation-history-filter-form"
        phx-change="filter"
        class="zaq-ingestion-chrome-actions zaq-ingestion-chrome-actions--end flex flex-wrap items-center gap-3"
      >
        <.searchable_select
          :if={@is_admin && @filter_scope == "all"}
          id="filter-team"
          name="team_id"
          label="Team"
          value={@filter_team_id}
          placeholder="Search team..."
          empty_label="All teams"
          compact={true}
          options={[{"All teams", "all"} | Enum.map(@teams, &{&1.name, &1.id})]}
        />

        <.searchable_select
          :if={@is_admin && @filter_scope == "all"}
          id="filter-person"
          name="person_id"
          label="Person"
          value={@filter_person_id}
          placeholder="Search person..."
          empty_label="All people"
          compact={true}
          on_search="search_people"
          options={[{"All people", "all"} | Enum.map(@people, &{&1.full_name, &1.id})]}
        />

        <.select
          id="history-status"
          name="status"
          label="Status"
          label_position="inline"
          value={@status}
          compact={true}
          options={[{"Active", "active"}, {"Archived", "archived"}]}
        />

        <.select
          id="channel_type"
          name="channel_type"
          label="Channel"
          label_position="inline"
          value={@filter_channel_type}
          compact={true}
          options={@channel_type_options}
        />
      </form>
    </div>
    """
  end
end
