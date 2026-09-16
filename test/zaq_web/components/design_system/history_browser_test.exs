defmodule ZaqWeb.Components.DesignSystem.HistoryBrowserTest do
  use Zaq.DataCase, async: true
  import Phoenix.LiveViewTest
  alias ZaqWeb.Components.DesignSystem.HistoryBrowser

  test "People reuses table and channel filters with pagination and no identity or destructive affordances" do
    conv = %{
      id: Ecto.UUID.generate(),
      title: "Owned",
      inserted_at: ~U[2026-09-15 10:00:00Z],
      updated_at: ~U[2026-09-15 10:00:00Z],
      channel_type: "api"
    }

    html =
      render_component(&HistoryBrowser.history_browser/1,
        conversations: [conv],
        conversation_count: 26,
        selectable: false,
        actions: false,
        status: "all",
        status_options: [{"All", "all"}, {"Active", "active"}, {"Archived", "archived"}],
        channel_type_options: [{"All", "all"}, {"API", "api"}],
        destination: fn id -> "/people/conversations/#{id}" end,
        page: 1
      )

    assert html =~ "history-conversations-table"
    assert html =~ "/people/conversations/#{conv.id}"
    assert html =~ "channel_type"
    assert html =~ "1–25 of 26"
    refute html =~ "All Users"
    refute html =~ "filter-person"
    refute html =~ "filter-team"
    refute html =~ "Mattermost"
    refute html =~ "Identity"
    refute html =~ "toggle_select"
    refute html =~ "archive_conversation"
    refute html =~ "delete_conversation"
    refute html =~ "/bo/"
  end

  test "BO defaults preserve selection, admin filters and destinations without a pager" do
    html =
      render_component(&HistoryBrowser.history_browser/1,
        conversations: [],
        conversation_count: 0,
        is_admin: true,
        filter_scope: "all"
      )

    assert html =~ "All Users"
    assert html =~ "filter-person"
    assert html =~ "select_all"
    refute html =~ "simple-pagination-range"
  end
end
