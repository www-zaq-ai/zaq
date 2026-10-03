defmodule ZaqWeb.Live.BO.Communication.ChannelHistoryLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Channels.{ChannelConfig, RetrievalChannel}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.History.Facts
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Engine.Messages.Incoming

  setup %{conn: conn} do
    admin = super_admin_fixture()
    {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})
    %{conn: init_test_session(conn, %{user_id: admin.id})}
  end

  test "Person-based titles stay primary for recipient-owned roots and direct chats", %{
    conn: conn
  } do
    {:ok, person} = People.create_person(%{full_name: "Alex Person"})

    for {provider, kind, style, title} <- [
          {"email:smtp", :replicated, "person_subject", "Alex Person: Quarterly plan"},
          {"telegram", :direct, "person", "Alex Person"}
        ] do
      config =
        %ChannelConfig{}
        |> ChannelConfig.changeset(%{
          name: "Named #{provider}",
          provider: provider,
          kind: "retrieval",
          url: "https://example.invalid",
          token: "fixture-token"
        })
        |> Zaq.Repo.insert!()

      {:ok, facts} =
        Facts.new(%{
          provider: provider,
          kind: kind,
          channel_config_id: config.id,
          channel_id: "peer",
          conversation_id: if(kind == :replicated, do: "root@example.com"),
          actor_person_id: person.id
        })

      {:ok, captured} =
        Conversations.capture_canonical_message(
          facts,
          %{
            role: "external",
            content: "Visible message",
            author_id: "peer",
            history_context: %{
              "author_person_id" => person.id,
              "participants" => [%{"person_id" => person.id, "role" => "sender"}],
              "title_style" => style,
              "subject" => "Quarterly plan"
            }
          },
          %{
            provider: provider,
            channel_config_id: config.id,
            provenance: "channel_adapter",
            source_scope: "INBOX"
          }
        )

      second =
        if kind == :replicated do
          {:ok, other} = People.create_person(%{full_name: "Second recipient"})

          {:ok, copy} =
            Conversations.capture_canonical_message(
              %{facts | actor_person_id: other.id},
              %{
                role: "external",
                content: "Visible message",
                history_context: %{
                  "author_person_id" => person.id,
                  "title_style" => style,
                  "subject" => "Quarterly plan"
                }
              },
              %{
                provider: provider,
                channel_config_id: config.id,
                provenance: "channel_adapter",
                source_scope: "INBOX"
              }
            )

          {other, copy}
        end

      {:ok, view, _} = live(conn, ~p"/bo/channels/history")
      assert has_element?(view, "#transcript-#{captured.transcript_id} a .truncate", title)
      assert has_element?(view, "#transcript-#{captured.transcript_id} p", config.name)
      {:ok, detail, _} = live(conn, ~p"/bo/channels/history/#{captured.transcript_id}")
      assert has_element?(detail, "#bo-header [data-testid='bo-main-page-heading']", title)

      if kind == :replicated do
        {other, copy} = second

        assert has_element?(
                 view,
                 "#transcript-#{copy.transcript_id} [data-replica-owner]",
                 other.full_name
               )

        assert has_element?(view, "#transcript-#{copy.transcript_id} a .truncate", title)
        {:ok, other_detail, _} = live(conn, ~p"/bo/channels/history/#{copy.transcript_id}")

        assert has_element?(
                 other_detail,
                 "#bo-header a[href='/bo/people?person_id=#{other.id}']",
                 other.full_name
               )

        assert has_element?(
                 view,
                 "#transcript-#{captured.transcript_id} [data-replica-owner]",
                 "Alex Person"
               )

        assert has_element?(
                 detail,
                 "#bo-header a[href='/bo/people?person_id=#{person.id}']",
                 "Alex Person"
               )

        refute render(detail) =~ "Recipient Person ID:"
        # The owner survives this merge. Merging away an owner is separately
        # blocked by the transcript FK and tracked in zaq-emb.27.15.
        {:ok, duplicate} = People.create_person(%{full_name: "Secondary identity"})
        assert {:ok, _} = People.merge_persons(other, [duplicate.id])
        {:ok, merged_detail, _} = live(conn, ~p"/bo/channels/history/#{copy.transcript_id}")

        assert has_element?(
                 merged_detail,
                 "#bo-header a[href='/bo/people?person_id=#{other.id}']",
                 other.full_name
               )
      else
        refute has_element?(view, "#transcript-#{captured.transcript_id} [data-replica-owner]")
      end
    end
  end

  test "super-admin sees actual stored nonmention and its scoped transcript", %{conn: conn} do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Live channel",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.invalid",
        token: "test-token"
      })
      |> Zaq.Repo.insert!()

    %RetrievalChannel{}
    |> RetrievalChannel.changeset(%{
      channel_config_id: config.id,
      channel_id: "room-1",
      channel_name: "Engineering",
      team_id: "team",
      team_name: "Team"
    })
    |> Zaq.Repo.insert!()

    {:ok, person} = People.create_person(%{"full_name" => "Alex"})

    {:ok, _} =
      People.add_channel(%{
        "person_id" => person.id,
        "platform" => "mattermost",
        "channel_identifier" => "alex",
        "channel_config_id" => config.id
      })

    incoming =
      Incoming.new(%{
        content: "Live nonmention",
        channel_id: "room-1",
        provider: :mattermost,
        author_id: "alex",
        message_id: "m1",
        routing_context: %{channel_config_id: config.id, history_kind: :channel}
      })

    {:ok, captured} = HistoryIngress.capture(incoming)
    message = Zaq.Repo.get!(Zaq.Engine.Conversations.Message, captured.message_id)
    {:ok, _} = Conversations.upsert_rating(message, %{person_id: person.id, rating: 5})
    {:ok, rated_view, _} = live(conn, ~p"/bo/channels/history/#{captured.transcript_id}")

    assert has_element?(
             rated_view,
             "#history-message-#{captured.message_id} [data-reaction-type='positive'][data-feedback-active='false'][data-read-only='true']",
             "1"
           )

    {:ok, facts} =
      Facts.new(%{
        provider: "mattermost",
        channel_config_id: config.id,
        channel_id: "room-1",
        kind: :channel,
        actor_person_id: person.id
      })

    {:ok, answer} =
      Conversations.capture_canonical_message(
        facts,
        %{role: "assistant", content: "Actual answer", external_message_id: "answer-1"},
        %{provider: "mattermost", channel_config_id: config.id, provenance: "provider_delivery"}
      )

    {:ok, thread} =
      Conversations.capture_canonical_message(
        %{facts | thread_id: "m1"},
        %{
          role: "external",
          content: "Thread reply",
          external_message_id: "reply-1",
          author_id: "alex"
        },
        %{provider: "mattermost", channel_config_id: config.id, provenance: "provider_event"}
      )

    answer_record = Zaq.Repo.get!(Zaq.Engine.Conversations.Message, answer.message_id)
    {:ok, _} = Conversations.upsert_rating(answer_record, %{person_id: person.id, rating: 1})

    {:ok, list_view, list} = live(conn, ~p"/bo/channels/history")
    assert list =~ "Live channel"
    assert list =~ "Engineering"
    refute list =~ "sender@example.com"
    refute list =~ "Showing transcripts"
    refute has_element?(list_view, "#channel-history-page")
    assert has_element?(list_view, "#transcript-#{captured.transcript_id}[phx-click]")

    assert has_element?(
             list_view,
             "#transcript-#{captured.transcript_id} a[href='/bo/channels/history?channel=#{captured.transcript_id}'][onclick='event.stopPropagation()']"
           )

    {:ok, _paged, empty_page} = live(conn, ~p"/bo/channels/history?offset=50")
    assert empty_page =~ "Previous 50"
    refute empty_page =~ "Live nonmention"

    {:ok, threads_view, threads_html} =
      live(conn, ~p"/bo/channels/history?channel=#{captured.transcript_id}&offset=50")

    assert has_element?(
             threads_view,
             "#channel-history-breadcrumb a[href='/bo/channels/history']",
             "Channel history"
           )

    assert has_element?(
             threads_view,
             "#channel-history-breadcrumb a[href='/bo/channels/history/#{captured.transcript_id}']",
             "Engineering"
           )

    assert has_element?(
             threads_view,
             "#channel-history-breadcrumb .zaq-breadcrumb-current",
             "Threads"
           )

    refute threads_html =~ "Back to channels"

    {:ok, view, detail} = live(conn, ~p"/bo/channels/history/#{captured.transcript_id}")
    assert detail =~ "Live nonmention"
    assert detail =~ "Engineering"
    refute detail =~ "Fixture-only"

    assert has_element?(
             view,
             "#channel-history-breadcrumb .zaq-breadcrumb-current",
             "Engineering"
           )

    assert has_element?(view, "#bo-header [data-testid='bo-main-page-heading']", "Engineering")
    assert has_element?(view, "#bo-header button[phx-click='open_access']")
    assert has_element?(view, "[data-testid='history-message-timeline']")
    assert has_element?(view, "[data-testid='history-date-separator']")
    assert has_element?(view, "[data-testid='chat-assistant-bubble'] img[alt='ZAQ']")
    refute has_element?(view, "#channel-history-context")
    refute has_element?(view, "section[aria-label='Messages'] h2")
    assert has_element?(view, "[data-testid='chat-user-bubble'][data-align='left']")

    refute has_element?(
             view,
             "[data-testid='chat-user-bubble'] button[phx-click='open_message_info']"
           )

    assert has_element?(view, "[data-testid='message-initials']")
    assert has_element?(view, "[data-testid='message-initials'][aria-label='Alex']", "A")

    assert has_element?(
             view,
             "[data-testid='chat-assistant-bubble'][data-align='right']",
             "Actual answer"
           )

    view
    |> element("button[phx-click='open_message_info'][phx-value-id='#{answer.message_id}']")
    |> render_click()

    assert has_element?(view, "[phx-click='close_message_info']")
    render_click(view, "close_message_info")

    refute has_element?(
             view,
             "button[phx-value-id='#{answer.message_id}'][data-feedback-active='true']"
           )

    assert has_element?(
             view,
             "#history-message-#{answer.message_id} button[data-reaction-type='negative'][aria-pressed='false']",
             "1"
           )

    view
    |> element(
      "button[phx-click='feedback'][phx-value-id='#{answer.message_id}'][phx-value-type='positive']"
    )
    |> render_click()

    assert has_element?(view, "button[phx-value-type='positive'][data-feedback-active='true']")

    assert has_element?(
             view,
             "#history-message-#{answer.message_id} button[data-reaction-type='positive'][aria-pressed='true']",
             "1"
           )

    assert has_element?(
             view,
             "#history-message-#{answer.message_id} button[data-reaction-type='negative'][aria-pressed='false']",
             "1"
           )

    refute has_element?(view, "[aria-label='Message ratings']")

    refute has_element?(view, "#channel-history-access")
    view |> element("button[phx-click='open_access']") |> render_click()
    assert has_element?(view, "#channel-history-access")

    view
    |> form("#manual-channel-history-grant", grant: %{person_id: person.id})
    |> render_submit()

    assert render(view) =~ "manual"
    assert has_element?(view, "button[phx-click='revoke'][phx-value-id='#{person.id}']")
    view |> element("button[phx-click='revoke'][phx-value-id='#{person.id}']") |> render_click()
    assert render(view) =~ "No current grants"
    transcript = Zaq.Repo.get!(Zaq.Engine.Conversations.Transcript, captured.transcript_id)
    {:ok, team} = People.create_team(%{name: "History readers"})

    assert {:ok, _} =
             Zaq.Permissions.grant(
               {transcript.permission_resource_type, transcript.permission_resource_id},
               %{team_id: team.id, access_rights: ["read"]}
             )

    {:ok, reloaded, _} = live(conn, ~p"/bo/channels/history/#{captured.transcript_id}")
    reloaded |> element("button[phx-click='open_access']") |> render_click()
    assert has_element?(reloaded, "#channel-access-grants", "Team #{team.id}")
    assert has_element?(reloaded, "#channel-access-grants", "read")
    refute has_element?(reloaded, "#channel-access-grants button[phx-click='revoke']")
    render_click(reloaded, "close_access")

    assert has_element?(
             reloaded,
             "button[phx-value-type='positive'][data-feedback-active='true']"
           )

    reloaded
    |> element("#history-message-#{answer.message_id} button[phx-value-type='negative']")
    |> render_click()

    assert has_element?(
             reloaded,
             "#history-message-#{answer.message_id} button[data-reaction-type='negative'][aria-pressed='true']",
             "2"
           )

    assert has_element?(
             reloaded,
             "#history-message-#{answer.message_id} button[data-reaction-type='positive'][aria-pressed='false']"
           )

    refute has_element?(
             reloaded,
             "#history-message-#{answer.message_id} [data-reaction-type='positive'] .zaq-chat-message__reaction-count"
           )

    {:ok, switched, _} = live(conn, ~p"/bo/channels/history/#{captured.transcript_id}")

    assert has_element?(
             switched,
             "#history-message-#{answer.message_id} button[data-reaction-type='negative'][aria-pressed='true']",
             "2"
           )

    {:ok, thread_view, _} = live(conn, ~p"/bo/channels/history/#{thread.transcript_id}")

    assert has_element?(
             thread_view,
             "#channel-history-breadcrumb a[href='/bo/channels/history/#{captured.transcript_id}']",
             "Engineering"
           )

    assert has_element?(
             thread_view,
             "#channel-history-breadcrumb a[href='/bo/channels/history?channel=#{captured.transcript_id}']",
             "Threads"
           )

    assert has_element?(
             thread_view,
             "#channel-history-breadcrumb .zaq-breadcrumb-current",
             "Live nonmention"
           )

    refute render(thread_view) =~ "Back to channel threads"

    assert has_element?(
             thread_view,
             "[data-testid='history-message-timeline'] #thread-root-message",
             "Live nonmention"
           )

    assert has_element?(
             thread_view,
             "[data-testid='history-message-timeline'] #history-message-#{thread.message_id}",
             "Thread reply"
           )
  end

  test "staff has no access to transcripts or list", %{conn: _conn} do
    staff = user_fixture()
    {:ok, staff} = Accounts.change_password(staff, %{password: "StrongPass1!"})
    conn = init_test_session(build_conn(), %{user_id: staff.id})

    {:ok, _view, html} = live(conn, ~p"/bo/channels/history")
    assert html =~ "Not authorized"
    refute html =~ "room-1"
  end
end
