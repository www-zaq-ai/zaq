defmodule Zaq.E2EPw.StreamedUpdatesTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  # Connector streamed-update preferences
  setup %{page: page, request: request} do
    reset_e2e_state(request)
    login_to_back_office(page)
    :ok
  end

  defp suffix, do: "#{Test.info().project.name}-#{System.system_time(:millisecond)}"

  defp enable_label, do: "Enable streamed message updates"

  test "native connector Edit modals retain and isolate streamed-update preferences", %{
    page: page
  } do
    goto_back_office_live(page, "/bo/channels/retrieval/mattermost")
    suffix = suffix()
    names = ["Stream workspace A #{suffix}", "Stream workspace B #{suffix}"]

    for name <- names do
      page |> Page.locator("#new-config-button") |> Locator.click!()
      modal = Page.locator(page, "#channel-config-modal")
      modal |> Locator.locator(~s|details[id^="stream-updates-"]|) |> Expect.to_have_count!(0)
      modal |> Locator.locator(~s|input[name="form[name]"]|) |> Locator.fill!(name)

      modal
      |> Locator.locator(~s|input[name="form[url]"]|)
      |> Locator.fill!("https://mattermost.example.test")

      modal
      |> Locator.locator(~s|input[name="form[token]"]|)
      |> Locator.fill!("synthetic-stream-test-token")

      modal |> Locator.locator("#form_enabled") |> Locator.uncheck!()
      modal |> Locator.locator(~s|button[type="submit"][form="config-form"]|) |> Locator.click!()
      Expect.to_be_hidden!(modal)
    end

    first =
      page
      |> Page.locator(~s|[id^="config-card-"]|)
      |> Locator.filter(has_text: Enum.at(names, 0))

    first |> Locator.locator(~s|[id^="edit-config-"]|) |> Locator.click!()
    modal = Page.locator(page, "#channel-config-modal")
    settings = Locator.locator(modal, ~s|details[id^="stream-updates-"]|)
    settings |> Locator.locator("summary") |> Locator.click!()

    modal
    |> Locator.locator(~s|input[name="form[name]"]|)
    |> Locator.fill!("Discarded native #{suffix}")

    settings |> Locator.get_by_label(enable_label(), exact: true) |> Locator.uncheck!()
    wait_for_live_view_settled(page)
    modal |> Locator.get_by_role(:button, name: "Cancel", exact: true) |> Locator.click!()
    Expect.to_be_visible!(first)
    first |> Locator.locator(~s|[id^="edit-config-"]|) |> Locator.click!()
    settings |> Locator.locator("summary") |> Locator.click!()

    modal
    |> Locator.locator(~s|input[name="form[name]"]|)
    |> Expect.to_have_value!(Enum.at(names, 0))

    settings |> Locator.get_by_label(enable_label(), exact: true) |> Expect.to_be_checked!()
    Expect.to_contain_text!(settings, "Progress/status messages are unaffected")

    Expect.to_contain_text!(
      settings,
      "When off, selected events can trigger updates without a minimum time interval."
    )

    settings
    |> Locator.locator(~s|input[name="live_updates[triggers][status]"]|)
    |> Expect.to_have_count!(0)

    modal
    |> Locator.get_by_role(:button, name: "Save streamed updates", exact: true)
    |> Expect.to_have_count!(0)

    modal |> Locator.locator("form") |> Expect.to_have_count!(1)
    page |> Page.locator("form form") |> Expect.to_have_count!(0)

    modal
    |> Locator.locator(~s|input[name="form[name]"]|)
    |> Locator.fill!("#{Enum.at(names, 0)} renamed")

    settings
    |> Locator.get_by_label("Minimum streamed-update interval (ms)")
    |> Locator.fill!("250")

    wait_for_live_view_settled(page)
    settings |> Locator.get_by_label("Tool activity", exact: true) |> Locator.uncheck!()
    wait_for_live_view_settled(page)
    settings |> Locator.get_by_label(enable_label(), exact: true) |> Locator.uncheck!()

    settings
    |> Locator.get_by_label("Minimum streamed-update interval (ms)")
    |> Expect.to_be_disabled!()

    modal |> Locator.locator(~s|button[type="submit"][form="config-form"]|) |> Locator.click!()
    Expect.to_be_hidden!(modal)
    Page.reload!(page)
    wait_for_live_view_connected(page)
    wait_for_live_view_settled(page)
    first |> Locator.locator(~s|[id^="edit-config-"]|) |> Locator.click!()
    settings |> Locator.locator("summary") |> Locator.click!()

    modal
    |> Locator.locator(~s|input[name="form[name]"]|)
    |> Expect.to_have_value!("#{Enum.at(names, 0)} renamed")

    settings
    |> Locator.get_by_label(enable_label(), exact: true)
    |> Expect.not_()
    |> Expect.to_be_checked!()

    settings
    |> Locator.get_by_label("Minimum streamed-update interval (ms)")
    |> Expect.to_have_value!("250")

    settings
    |> Locator.get_by_label("Tool activity", exact: true)
    |> Expect.not_()
    |> Expect.to_be_checked!()

    modal |> Locator.get_by_role(:button, name: "Cancel", exact: true) |> Locator.click!()

    second =
      page
      |> Page.locator(~s|[id^="config-card-"]|)
      |> Locator.filter(has_text: Enum.at(names, 1))

    second |> Locator.locator(~s|[id^="edit-config-"]|) |> Locator.click!()
    settings |> Locator.locator("summary") |> Locator.click!()
    settings |> Locator.get_by_label(enable_label(), exact: true) |> Expect.to_be_checked!()

    settings
    |> Locator.get_by_label("Minimum streamed-update interval (ms)")
    |> Expect.to_have_value!("100")

    settings |> Locator.get_by_label("Tool activity", exact: true) |> Expect.to_be_checked!()
  end

  test "widget Edit modal saves details and streamed preferences together and Cancel discards drafts",
       %{page: page} do
    goto_back_office_live(page, "/bo/channels/retrieval/web_widget")
    suffix = suffix()
    name = "Stream preferences widget #{suffix}"
    renamed = "Renamed stream widget #{suffix}"
    page |> Page.locator("#new-widget-config") |> Locator.click!()
    modal = Page.locator(page, "#widget-config-modal")
    modal |> Locator.locator(~s|input[name="widget[name]"]|) |> Locator.fill!(name)
    page |> Page.locator("#save-widget-config") |> Locator.click!()
    settings = Locator.locator(modal, ~s|details[id^="stream-updates-"]|)
    settings |> Locator.locator("summary") |> Locator.click!()

    modal
    |> Locator.locator(~s|input[name="widget[name]"]|)
    |> Locator.fill!("Discarded widget #{suffix}")

    settings |> Locator.get_by_label("Reasoning", exact: true) |> Locator.uncheck!()
    wait_for_live_view_settled(page)
    page |> Page.locator("#close-widget-modal") |> Locator.click!()
    card = page |> Page.locator(~s|[id^="widget-connector-"]|) |> Locator.filter(has_text: name)
    Expect.to_be_visible!(card)
    card |> Locator.locator(~s|[id^="edit-widget-"]|) |> Locator.click!()
    settings |> Locator.locator("summary") |> Locator.click!()
    modal |> Locator.locator(~s|input[name="widget[name]"]|) |> Expect.to_have_value!(name)
    settings |> Locator.get_by_label("Reasoning", exact: true) |> Expect.to_be_checked!()
    modal |> Locator.locator("form") |> Expect.to_have_count!(1)

    modal
    |> Locator.get_by_role(:button, name: "Save streamed updates", exact: true)
    |> Expect.to_have_count!(0)

    Expect.to_contain_text!(settings, "Answer and reasoning text still use internal batching.")
    page |> Page.locator("form form") |> Expect.to_have_count!(0)
    modal |> Locator.locator(~s|input[name="widget[name]"]|) |> Locator.fill!(renamed)

    settings
    |> Locator.get_by_label("Minimum streamed-update interval (ms)")
    |> Locator.fill!("350")

    wait_for_live_view_settled(page)

    settings
    |> Locator.get_by_label("Limit streamed update frequency", exact: true)
    |> Locator.uncheck!()

    wait_for_live_view_settled(page)
    settings |> Locator.get_by_label("Reasoning", exact: true) |> Locator.uncheck!()
    wait_for_live_view_settled(page)
    modal |> Locator.locator(~s|input[name="widget[name]"]|) |> Expect.to_have_value!(renamed)
    page |> Page.locator("#save-widget-config") |> Locator.click!()

    page
    |> Page.locator(~s|[id^="widget-connector-"]|)
    |> Locator.filter(has_text: renamed)
    |> Expect.to_be_visible!()

    page |> Page.locator("#close-widget-modal") |> Locator.click!()
    Page.reload!(page)
    wait_for_live_view_connected(page)
    wait_for_live_view_settled(page)

    page
    |> Page.locator(~s|[id^="widget-connector-"]|)
    |> Locator.filter(has_text: renamed)
    |> Locator.locator(~s|[id^="edit-widget-"]|)
    |> Locator.click!()

    settings |> Locator.locator("summary") |> Locator.click!()

    settings
    |> Locator.get_by_label("Limit streamed update frequency", exact: true)
    |> Expect.not_()
    |> Expect.to_be_checked!()

    settings
    |> Locator.get_by_label("Reasoning", exact: true)
    |> Expect.not_()
    |> Expect.to_be_checked!()

    settings
    |> Locator.get_by_label("Minimum streamed-update interval (ms)")
    |> Expect.to_have_value!("350")

    settings
    |> Locator.get_by_label("Minimum streamed-update interval (ms)")
    |> Expect.to_be_disabled!()

    Expect.to_contain_text!(settings, "Progress/status messages are unaffected")
  end
end
