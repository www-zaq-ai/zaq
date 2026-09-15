defmodule ZaqWeb.Components.DesignSystem.HistoryBrowser do
  @moduledoc """
  Stateless full-page history browser composed from the existing history toolbar,
  selection bar and conversation table. Callers own filters, routes and authority.
  Pagination is optional; the BO's existing unpaged behavior is the default.
  """
  use Phoenix.Component
  import ZaqWeb.History.ConversationFilters
  import ZaqWeb.History.ConversationTable
  import ZaqWeb.History.BulkSelectionBar
  import ZaqWeb.Components.DesignSystem.SimplePagination
  alias ZaqWeb.History.ConversationFilters
  alias ZaqWeb.History.ConversationRow

  attr :conversations, :list, required: true
  attr :conversation_count, :integer, required: true
  attr :status, :string, default: "active"
  attr :status_options, :list, default: [{"Active", "active"}, {"Archived", "archived"}]
  attr :is_admin, :boolean, default: false
  attr :filter_scope, :string, default: "own"
  attr :filter_channel_type, :string, default: "all"
  attr :channel_type_options, :list, default: nil
  attr :filter_team_id, :string, default: "all"
  attr :filter_person_id, :string, default: "all"
  attr :teams, :list, default: []
  attr :people, :list, default: []
  attr :selected, :any, default: MapSet.new()
  attr :live_action, :atom, default: :index
  attr :selectable, :boolean, default: true
  attr :actions, :boolean, default: true
  attr :destination, :any, default: &ConversationRow.bo_destination/1
  attr :page, :integer, default: nil

  def history_browser(assigns) do
    assigns =
      assign(
        assigns,
        :channel_type_options,
        assigns.channel_type_options || ConversationFilters.channel_type_options()
      )

    ~H"""
    <div class="min-w-0 w-full max-w-full zaq-layout-stack">
      <.conversation_filters
        conversation_count={@conversation_count}
        status={@status}
        status_options={@status_options}
        is_admin={@is_admin}
        filter_scope={@filter_scope}
        filter_channel_type={@filter_channel_type}
        channel_type_options={@channel_type_options}
        filter_team_id={@filter_team_id}
        filter_person_id={@filter_person_id}
        teams={@teams}
        people={@people}
      />
      <.bulk_selection_bar
        :if={@selectable && @actions}
        selected_count={MapSet.size(@selected)}
        live_action={@live_action}
      />
      <.conversation_table
        conversations={@conversations}
        selected={@selected}
        live_action={@live_action}
        is_admin={@is_admin}
        filter_scope={@filter_scope}
        selectable={@selectable}
        actions={@actions}
        destination={@destination}
      />
      <.simple_pagination :if={@page} page={@page} per_page={25} total_count={@conversation_count} />
    </div>
    """
  end
end
