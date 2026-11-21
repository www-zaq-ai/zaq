defmodule Zaq.E2EPw.HistoryTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  @history_path "/bo/history"

  defp pick_history_select(page, container_id, option_label) do
    container = Page.locator(page, "##{container_id}")
    container |> Locator.locator("[data-select-trigger]") |> Locator.click!()
    container |> Locator.locator(~s|[data-select-option="#{option_label}"]|) |> Locator.click!()
    wait_for_live_view_settled(page)
  end

  defp row(page, text), do: page |> Page.locator("tr") |> Locator.filter(has_text: text)

  # BO History page
  setup %{page: page, request: request} do
    reset_e2e_state(request)
    login_to_back_office(page)
    :ok
  end

  test "renders filters, admin scope, and table shell", %{page: page} do
    goto_back_office_live(page, @history_path)

    page |> Page.locator("#history-status-trigger") |> Expect.to_be_visible!()
    page |> Page.locator("#history-status-trigger") |> Expect.to_contain_text!("Active")
    page |> Page.locator("#channel_type-trigger") |> Expect.to_be_visible!()

    for name <- ["Conversation", "Channel", "Started", "Updated"] do
      page |> Page.get_by_role(:columnheader, name: name) |> Expect.to_be_visible!()
    end

    page |> Page.get_by_text(~r/\d+ conversations/) |> Expect.to_be_visible!()

    page |> Page.get_by_role(:button, name: "My History") |> Expect.to_be_visible!()
    page |> Page.get_by_role(:button, name: "All Users") |> Expect.to_be_visible!()

    row(page, "E2E Unsupported Source Conversation") |> Expect.to_be_visible!()
  end

  test "archived status lists archived conversations only", %{page: page, request: request} do
    archived_title = "E2E History Archived #{System.system_time(:millisecond)}"

    create_e2e_conversation(request, %{
      title: archived_title,
      channel_type: "bo",
      status: "archived"
    })

    goto_back_office_live(page, @history_path)
    row(page, archived_title) |> Expect.not_() |> Expect.to_be_visible!()

    pick_history_select(page, "history-status", "Archived")
    Expect.to_have_url!(page, ~r{/bo/history/archived})
    row(page, archived_title) |> Expect.to_be_visible!()

    archived_row = row(page, archived_title)
    archived_row |> Locator.get_by_role(:button, name: "Archive") |> Expect.to_have_count!(0)

    pick_history_select(page, "history-status", "Active")
    Expect.to_have_url!(page, ~r{/bo/history$})
    row(page, archived_title) |> Expect.not_() |> Expect.to_be_visible!()
  end

  test "channel filter narrows rows by channel_type", %{page: page, request: request} do
    mm_title = "E2E History Mattermost #{System.system_time(:millisecond)}"

    create_e2e_conversation(request, %{
      title: mm_title,
      channel_type: "mattermost",
      channel_user_id: "e2e_mm_user"
    })

    goto_back_office_live(page, @history_path)
    row(page, "E2E Unsupported Source Conversation") |> Expect.to_be_visible!()

    pick_history_select(page, "channel_type", "Mattermost")

    row(page, mm_title) |> Expect.to_be_visible!()
    row(page, "E2E Unsupported Source Conversation") |> Expect.not_() |> Expect.to_be_visible!()
  end

  test "bulk selection bar and select-all", %{page: page, request: request} do
    one = "E2E History Bulk One #{System.system_time(:millisecond)}"
    two = "E2E History Bulk Two #{System.system_time(:millisecond)}"
    create_e2e_conversation(request, %{title: one, channel_type: "bo"})
    create_e2e_conversation(request, %{title: two, channel_type: "bo"})

    goto_back_office_live(page, @history_path)
    pick_history_select(page, "channel_type", "BO")

    row_one = row(page, one)
    Expect.to_be_visible!(row_one)

    row_one
    |> Locator.locator(~s|input[type="checkbox"][phx-click="toggle_select"]|)
    |> Locator.check!()

    wait_for_live_view_settled(page)

    page |> Page.get_by_text("1 selected") |> Expect.to_be_visible!()
    page |> Page.locator(~s|button[phx-click="bulk_archive"]|) |> Expect.to_be_visible!()

    page
    |> Page.locator(~s|thead input[type="checkbox"][phx-click="select_all"]|)
    |> Locator.check!()

    wait_for_live_view_settled(page)

    page |> Page.get_by_text("3 selected") |> Expect.to_be_visible!()
  end
end
