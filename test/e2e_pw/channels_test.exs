defmodule Zaq.E2EPw.ChannelsTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  @channels_index "/bo/channels"
  @google_drive_provider "/bo/channels/data_source/google_drive"

  # Keep in sync with @retrieval_preview / @data_source_preview in channels_index_live.ex
  @retrieval_preview ["slack", "teams", "mattermost", "discord", "telegram"]
  @data_source_preview ["disk", "google_drive", "sharepoint"]

  # Channels index & provider UI
  setup %{page: page, request: request} do
    reset_e2e_state(request)
    login_to_back_office(page)
    :ok
  end

  test "channels index shows provider icon strip on category cards", %{page: page} do
    goto_back_office_live(page, @channels_index)
    wait_for_live_view_settled(page)

    page_title = Page.get_by_test_id(page, "bo-main-page-heading")
    Expect.to_be_visible!(page_title)
    Expect.to_have_text!(page_title, "Channels")

    retrieval_icons = Page.locator(page, ~s|[data-testid="channels-index-retrieval-icons"]|)
    Expect.to_be_visible!(retrieval_icons)

    for id <- @retrieval_preview do
      retrieval_icons
      |> Locator.locator(~s|[data-channel-preview="#{id}"]|)
      |> Expect.to_be_visible!()
    end

    data_source_icons = Page.locator(page, ~s|[data-testid="channels-index-data-source-icons"]|)
    Expect.to_be_visible!(data_source_icons)

    for id <- @data_source_preview do
      data_source_icons
      |> Locator.locator(~s|[data-channel-preview="#{id}"]|)
      |> Expect.to_be_visible!()
    end
  end

  test "provider page opens capabilities form_dialog and closes", %{page: page} do
    goto_back_office_live(page, @google_drive_provider)
    wait_for_live_view_settled(page)

    page |> Page.get_by_test_id("bo-main-page-heading") |> Expect.to_have_text!("Google Drive")

    trigger = Page.locator(page, ~s|[data-testid="channel-capabilities-trigger"]|)
    Expect.to_be_visible!(trigger)
    Locator.click!(trigger)
    wait_for_live_view_settled(page)

    modal = Page.get_by_role(page, :dialog, name: "Capabilities")
    Expect.to_be_visible!(modal)
    modal |> Locator.get_by_role(:heading, name: "Capabilities") |> Expect.to_be_visible!()

    modal |> Locator.get_by_test_id("channel-capabilities-close") |> Locator.click!()
    wait_for_live_view_settled(page)
    Expect.to_be_hidden!(modal)
  end

  test "provider new config flow exposes Connect credential form in modal", %{page: page} do
    goto_back_office_live(page, @google_drive_provider)
    wait_for_live_view_settled(page)

    page |> Page.locator("#new-config-button") |> Locator.click!()
    wait_for_live_view_settled(page)

    page |> Page.locator("#config-form") |> Expect.to_be_visible!()

    page |> Page.locator(~s|[phx-click="open_new_credential"]|) |> Locator.click!()
    wait_for_live_view_settled(page)

    page |> Page.locator("#new-credential-modal") |> Expect.to_be_visible!()
    page |> Page.locator("#connect-credential-form") |> Expect.to_be_visible!()
    page |> Page.locator(~s|input[name="credential[name]"]|) |> Expect.to_be_visible!()

    page
    |> Page.locator("#new-credential-modal")
    |> Locator.get_by_role(:button, name: "Close dialog")
    |> Locator.click!()

    wait_for_live_view_settled(page)
    page |> Page.locator("#new-credential-modal") |> Expect.to_be_hidden!()
  end
end
