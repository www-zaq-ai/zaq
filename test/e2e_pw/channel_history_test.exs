defmodule Zaq.E2EPw.ChannelHistoryTest do
  use Zaq.E2EPw.Case

  import Zaq.E2EPw.BO

  # BO Channel History
  setup %{page: page, request: request} do
    reset_e2e_state(request)
    fixture = seed_e2e_channel_history(request)
    login_to_back_office(page)
    %{fixture: fixture}
  end

  test "shows passive shared history and inherited thread context", %{
    page: page,
    fixture: fixture
  } do
    goto_back_office_live(page, "/bo/channels/history")

    room = Page.locator(page, "#transcript-#{fixture["shared_transcript_id"]}")
    Expect.to_contain_text!(room, "E2E Engineering")
    Expect.to_contain_text!(room, "shared")

    goto_back_office_live(page, "/bo/channels/history/#{fixture["shared_transcript_id"]}")

    page
    |> Page.get_by_text("Passive update retained without response")
    |> Expect.to_be_visible!()

    page |> Page.locator("[data-testid='chat-assistant-bubble']") |> Expect.to_have_count!(0)

    goto_back_office_live(page, "/bo/channels/history/#{fixture["thread_transcript_id"]}")

    page
    |> Page.locator("#thread-root-message")
    |> Expect.to_contain_text!("Passive update retained without response")

    page
    |> Page.locator("#history-message-#{fixture["thread_message_id"]}")
    |> Expect.to_contain_text!("Thread follow-up")

    page
    |> Page.locator("#history-message-#{fixture["thread_answer_id"]}")
    |> Expect.to_contain_text!("Thread answer")
  end

  test "keeps provider access when manual access is revoked and restored", %{
    page: page,
    fixture: fixture
  } do
    goto_back_office_live(page, "/bo/channels/history/#{fixture["shared_transcript_id"]}")
    page |> Page.get_by_role(:button, name: "Manage channel access") |> Locator.click!()

    person = "Person #{fixture["manual_person_id"]}"
    grants = Page.locator(page, "#channel-access-grants")
    Expect.to_contain_text!(grants, "channel_history:provider:e2e")
    Expect.to_contain_text!(grants, person)
    refresh = Page.get_by_role(page, :button, name: "Refresh Mattermost membership")
    Expect.to_be_visible!(refresh)
    Locator.click!(refresh)

    page
    |> Page.get_by_text("Provider access unchanged: refresh failed or incomplete")
    |> Expect.to_be_visible!()

    Expect.to_contain_text!(grants, "channel_history:provider:e2e")

    manual_row = grants |> Locator.locator("tr") |> Locator.filter(has_text: person)
    manual_row |> Locator.get_by_role(:button, name: "Revoke manual") |> Locator.click!()
    wait_for_live_view_settled(page)
    Expect.to_contain_text!(grants, "channel_history:provider:e2e")
    grants |> Expect.not_() |> Expect.to_contain_text!(person)

    page
    |> Page.locator("#channel-history-person")
    |> Locator.fill!(to_string(fixture["manual_person_id"]))

    page |> Page.get_by_role(:button, name: "Grant read access") |> Locator.click!()
    wait_for_live_view_settled(page)
    Expect.to_contain_text!(grants, person)
    Expect.to_contain_text!(grants, "manual")

    goto_back_office_live(page, "/bo/channels/history/#{fixture["replicated_transcript_id"]}")
    page |> Page.get_by_role(:button, name: "Manage channel access") |> Locator.click!()

    page
    |> Page.get_by_text(~r/Provider membership refresh is unsupported/)
    |> Expect.to_be_visible!()
  end

  test "presents merged replica ownership and restricted legacy evidence", %{
    page: page,
    fixture: fixture
  } do
    goto_back_office_live(page, "/bo/channels/history/#{fixture["replicated_transcript_id"]}")

    page
    |> Page.get_by_text("Recipient: #{fixture["replica_owner_name"]}")
    |> Expect.to_be_visible!()

    page |> Page.get_by_text("Recipient-specific answer") |> Expect.to_be_visible!()
    page |> Page.get_by_text("invoice.pdf") |> Expect.to_be_visible!()

    page
    |> Page.locator(
      "#history-message-#{fixture["replicated_message_id"]} [data-reaction-type='positive']"
    )
    |> Expect.to_contain_text!("2")

    goto_back_office_live(page, "/bo/channels/history/#{fixture["legacy_transcript_id"]}")
    page |> Page.get_by_text(~r/Restricted legacy snapshot/) |> Expect.to_be_visible!()
    page |> Page.get_by_text("Legacy answer with preserved evidence") |> Expect.to_be_visible!()
    page |> Page.get_by_text("legacy-report.pdf") |> Expect.to_be_visible!()

    page
    |> Page.locator(
      "#history-message-#{fixture["legacy_message_id"]} button[phx-click='open_message_info']"
    )
    |> Locator.click!()

    page |> Page.get_by_test_id("message-info-popin") |> Expect.to_be_visible!()
    page |> Page.get_by_text("legacy-search") |> Expect.to_be_visible!()
  end

  test "denies transcript inspection to a non-super-admin", %{page: page, fixture: fixture} do
    login_to_back_office(page,
      username: fixture["viewer_username"],
      password: fixture["viewer_password"],
      real_login: true,
      return_to: "/bo/channels/history/#{fixture["shared_transcript_id"]}"
    )

    page |> Page.get_by_text("Not authorized") |> Expect.to_be_visible!()

    page
    |> Page.get_by_text("Only a current BO super-admin can inspect all channel transcripts.")
    |> Expect.to_be_visible!()

    page
    |> Page.get_by_text("Passive update retained without response")
    |> Expect.not_()
    |> Expect.to_be_visible!()
  end
end
