defmodule ZaqWeb.Live.BO.Communication.ChannelHistoryLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Channels.RetrievalChannel
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.History.Facts
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.OpenAIStub

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
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
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

    {:ok, second_answer_facts} =
      Facts.new(%{
        provider: "mattermost",
        channel_config_id: config.id,
        channel_id: "room-1",
        kind: :channel,
        actor_person_id: person.id
      })

    {:ok, second_answer} =
      Conversations.capture_canonical_message(
        second_answer_facts,
        %{role: "assistant", content: "Second answer", external_message_id: "answer-2"},
        %{provider: "mattermost", channel_config_id: config.id, provenance: "provider_delivery"}
      )

    Zaq.Repo.get!(Zaq.Engine.Conversations.Message, second_answer.message_id)
    |> Ecto.Changeset.change(trace: [%{"tool_name" => "second.lookup", "status" => "ok"}])
    |> Zaq.Repo.update!()

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

    for index <- 1..48 do
      {:ok, page_facts} =
        Facts.new(%{
          provider: "mattermost",
          channel_config_id: config.id,
          channel_id: "room-1",
          kind: :channel,
          actor_person_id: person.id
        })

      {:ok, _} =
        Conversations.capture_canonical_message(
          page_facts,
          %{
            role: "external",
            content: "Page filler #{index}",
            external_message_id: "page-filler-#{index}",
            author_id: "alex"
          },
          %{provider: "mattermost", channel_config_id: config.id, provenance: "provider_event"}
        )
    end

    answer_record = Zaq.Repo.get!(Zaq.Engine.Conversations.Message, answer.message_id)

    answer_record
    |> Ecto.Changeset.change(
      model: "model-test",
      metadata: %{"agent" => "Trace fixture"},
      trace: [%{"tool_name" => "history.lookup", "status" => "ok", "response" => "trace payload"}]
    )
    |> Zaq.Repo.update!()

    {:ok, _} = Conversations.upsert_rating(answer_record, %{person_id: person.id, rating: 1})

    {:ok, list_view, list} = live(conn, ~p"/bo/channels/history")
    assert list =~ "Live channel"
    assert list =~ "Engineering"
    refute list =~ "sender@example.com"
    refute list =~ "Showing transcripts"
    refute has_element?(list_view, "#channel-history-page")
    assert has_element?(list_view, "#transcript-#{captured.transcript_id}[phx-click]")

    list_view
    |> form("#channel-history-filter", filter: %{query: "ENGINE"})
    |> render_change()

    assert has_element?(list_view, "#transcript-#{captured.transcript_id}")
    assert has_element?(list_view, "#channel-history-search[value='ENGINE']")

    list_view
    |> form("#channel-history-filter", filter: %{query: "no matching transcript"})
    |> render_change()

    assert has_element?(
             list_view,
             "#channel-history-list",
             "No captured transcripts on this page"
           )

    long_filter = String.duplicate("x", 120)

    list_view
    |> form("#channel-history-filter", filter: %{query: long_filter})
    |> render_change()

    truncated_filter = String.slice(long_filter, 0, 100)
    assert has_element?(list_view, "#channel-history-search[value='#{truncated_filter}']")

    list_view
    |> form("#channel-history-filter", filter: %{query: ""})
    |> render_change()

    # Forged events must not widen the server-side list filter or dispatch a
    # message operation when no detail transcript is loaded.
    before_forged_filter = render(list_view)
    render_hook(list_view, "filter", %{"filter" => %{"query" => 123}})
    assert render(list_view) == before_forged_filter
    render_hook(list_view, "open_message_info", %{"id" => answer.message_id})
    assert render(list_view) =~ "Message information unavailable"
    render_hook(list_view, "feedback", %{"id" => answer.message_id, "type" => "positive"})
    assert render(list_view) =~ "Could not save feedback"
    render_hook(list_view, "refresh", %{})
    refute render(list_view) =~ "Provider access refreshed"
    list_before_access_events = render(list_view)
    render_hook(list_view, "grant", %{"grant" => %{"person_id" => "1"}})
    render_hook(list_view, "revoke", %{"id" => "1"})
    assert render(list_view) == list_before_access_events

    assert has_element?(
             list_view,
             "#transcript-#{captured.transcript_id} a[href='/bo/channels/history?channel=#{captured.transcript_id}'][onclick='event.stopPropagation()']"
           )

    {:ok, _paged, empty_page} = live(conn, ~p"/bo/channels/history?offset=50")
    assert empty_page =~ "Previous 50"
    refute empty_page =~ "Live nonmention"

    for query <- ["offset=-1", "offset=abc", "offset[]=1"] do
      {:ok, _invalid_cursor, html} = live(conn, "/bo/channels/history?#{query}")
      assert html =~ "History unavailable"
    end

    for query <- ["after=abc", "after=0junk"] do
      {:ok, _invalid_cursor, html} =
        live(conn, "/bo/channels/history/#{captured.transcript_id}?#{query}")

      assert html =~ "Transcript unavailable"
    end

    {:ok, _nonbinary_cursor, nonbinary_html} =
      live(conn, "/bo/channels/history/#{captured.transcript_id}?after[]=1")

    assert nonbinary_html =~ "Transcript unavailable"

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

    view
    |> element("button[phx-click='copy_message'][phx-value-text='Actual answer']")
    |> render_click()

    assert_push_event(view, "clipboard", %{text: "Actual answer"})

    # A forged info request cannot replace the currently selected message with
    # another transcript's message or reveal its metadata.
    render_hook(view, "open_message_info", %{"id" => thread.message_id})
    assert render(view) =~ "Message information unavailable"
    refute render(view) =~ "Support Agent"
    render_hook(view, "open_message_info", %{"id" => "not-a-message-uuid"})
    assert render(view) =~ "Message information unavailable"
    render_hook(view, "feedback", %{"id" => thread.message_id, "type" => "positive"})
    assert render(view) =~ "Could not save feedback"
    assert has_element?(view, "#history-message-#{answer.message_id}", "Actual answer")
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
    assert has_element?(view, "[data-testid^='trace-row-']")
    view |> element("[data-testid^='trace-row-']") |> render_click()
    assert has_element?(view, "[data-testid^='trace-details-']", "trace payload")
    render_hook(view, "open_message_info", %{"id" => thread.message_id})
    assert has_element?(view, "[data-testid^='trace-details-']", "trace payload")
    view |> element("[data-testid^='trace-row-']") |> render_click()
    refute has_element?(view, "[data-testid^='trace-details-']")
    view |> element("[data-testid^='trace-row-']") |> render_click()
    assert has_element?(view, "[data-testid^='trace-details-']", "trace payload")

    view
    |> element(
      "button[phx-click='open_message_info'][phx-value-id='#{second_answer.message_id}']"
    )
    |> render_click()

    assert has_element?(view, "[data-testid^='trace-row-']")
    refute has_element?(view, "[data-testid^='trace-details-']")
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
    render_hook(view, "refresh", %{})
    assert render(view) =~ "Provider refresh is unsupported for this transcript"

    view
    |> form("#manual-channel-history-grant", grant: %{person_id: person.id})
    |> render_submit()

    assert render(view) =~ "manual"
    assert has_element?(view, "button[phx-click='revoke'][phx-value-id='#{person.id}']")

    for invalid_id <- ["0", "-1", "12junk", "", 12] do
      render_hook(view, "grant", %{"grant" => %{"person_id" => invalid_id}})
      assert render(view) =~ "Could not update manual access"
    end

    render_hook(view, "grant", %{"grant" => %{"person_id" => "999999999"}})
    assert render(view) =~ "Could not update manual access"

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

    Zaq.Repo.get!(Zaq.Engine.Conversations.Message, captured.message_id)
    |> Ecto.Changeset.change(
      content: "",
      attachments: [%{"name" => "root-attachment.pdf", "mime_type" => "application/pdf"}]
    )
    |> Zaq.Repo.update!()

    {:ok, _attachment_preview, attachment_html} =
      live(conn, ~p"/bo/channels/history?channel=#{captured.transcript_id}")

    assert attachment_html =~ "Attachment"

    {:ok, first_message_page, _} = live(conn, ~p"/bo/channels/history/#{captured.transcript_id}")
    assert has_element?(first_message_page, "a[href*='after=50']", "Next 50 messages")
    first_message_page |> element("a[href*='after=50']") |> render_click()

    last_filler =
      Zaq.Repo.get_by!(Zaq.Engine.Conversations.Message, external_message_id: "page-filler-48")

    assert has_element?(
             first_message_page,
             "#history-message-#{last_filler.id}",
             "Page filler 48"
           )

    refute has_element?(first_message_page, "#history-message-#{captured.message_id}")
  end

  test "staff has no access to transcripts or list", %{conn: _conn} do
    staff = user_fixture()
    {:ok, staff} = Accounts.change_password(staff, %{password: "StrongPass1!"})
    conn = init_test_session(build_conn(), %{user_id: staff.id})

    {:ok, _view, html} = live(conn, ~p"/bo/channels/history")
    assert html =~ "Not authorized"
    refute html =~ "room-1"
  end

  test "refresh reconciles a complete local Mattermost membership snapshot", %{conn: conn} do
    room_id = "abcdefghijklmnopqrstuvwx12"

    handler = fn request, _body ->
      cond do
        request.request_path == "/api/v4/channels/#{room_id}/members" ->
          {200, [%{"user_id" => "alex"}]}

        request.request_path == "/api/v4/users/alex" ->
          {200, %{"id" => "alex", "username" => "alex", "first_name" => "Alex"}}

        true ->
          {404, %{}}
      end
    end

    {child, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child)
    config_url = String.trim_trailing(endpoint, "/v1")
    {config, person, captured} = shared_history_fixture(config_url, room_id)

    {:ok, reader} = People.create_person(%{full_name: "Manual reader"})
    {:ok, view, _} = live(conn, ~p"/bo/channels/history/#{captured.transcript_id}")
    view |> element("button[phx-click='open_access']") |> render_click()

    view
    |> form("#manual-channel-history-grant", grant: %{person_id: reader.id})
    |> render_submit()

    view |> element("button[phx-click='refresh']") |> render_click()
    assert render(view) =~ "Provider access refreshed (1 linked People)"

    assert_receive {:openai_request, "GET", "/api/v4/channels/" <> ^room_id <> "/members", query,
                    _}

    assert query =~ "per_page=200"

    # Both provider-derived and independent manual grants remain visible and
    # persisted after the refresh.
    assert has_element?(view, "#channel-access-grants", "Person #{person.id}")
    assert has_element?(view, "#channel-access-grants", "Person #{reader.id}")
    transcript = Zaq.Repo.get!(Zaq.Engine.Conversations.Transcript, captured.transcript_id)

    grants =
      Zaq.Permissions.list(
        {transcript.permission_resource_type, transcript.permission_resource_id}
      )

    assert Enum.any?(grants, fn grant ->
             grant.person_id == person.id and
               grant.source_key == "channel_history:provider:mattermost"
           end)

    assert Enum.any?(grants, &(&1.person_id == reader.id and &1.source_key == "manual"))
    assert config.id == transcript.channel_config_id
  end

  test "failed or incomplete provider refresh preserves existing grants", %{conn: conn} do
    room_id = "zyxwvutsrqponmlkjihgfedcba"

    calls = start_supervised!({Agent, fn -> 0 end})

    handler = fn request, _body ->
      if request.request_path == "/api/v4/users/alex" do
        {200, %{"id" => "alex", "username" => "alex", "first_name" => "Alex"}}
      else
        Agent.get_and_update(calls, fn count -> {count, count + 1} end)
        |> case do
          0 -> {200, [%{"user_id" => "alex"}]}
          _ -> {500, %{}}
        end
      end
    end

    {child, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child)

    {_config, person, captured} =
      shared_history_fixture(String.trim_trailing(endpoint, "/v1"), room_id)

    {:ok, reader} = People.create_person(%{full_name: "Preserved reader"})
    {:ok, view, _} = live(conn, ~p"/bo/channels/history/#{captured.transcript_id}")
    view |> element("button[phx-click='open_access']") |> render_click()

    view
    |> form("#manual-channel-history-grant", grant: %{person_id: reader.id})
    |> render_submit()

    view |> element("button[phx-click='refresh']") |> render_click()
    assert render(view) =~ "Provider access refreshed (1 linked People)"

    assert_receive {:openai_request, "GET", "/api/v4/channels/" <> ^room_id <> "/members", _query,
                    _}

    assert has_element?(view, "#channel-access-grants", "Person #{reader.id}")

    transcript = Zaq.Repo.get!(Zaq.Engine.Conversations.Transcript, captured.transcript_id)
    resource = {transcript.permission_resource_type, transcript.permission_resource_id}

    grants_before_failure =
      resource
      |> Zaq.Permissions.list()
      |> Enum.map(fn grant ->
        {{grant.person_id, grant.team_id}, grant.source_key, Enum.sort(grant.access_rights)}
      end)
      |> Enum.sort()

    view |> element("button[phx-click='refresh']") |> render_click()
    assert render(view) =~ "Provider access unchanged: refresh failed or incomplete"

    assert_receive {:openai_request, "GET", "/api/v4/channels/" <> ^room_id <> "/members", _query,
                    _}

    assert has_element?(view, "#channel-access-grants", "Person #{reader.id}")
    assert has_element?(view, "#channel-access-grants", "Person #{person.id}")

    grants_after_failure =
      resource
      |> Zaq.Permissions.list()
      |> Enum.map(fn grant ->
        {{grant.person_id, grant.team_id}, grant.source_key, Enum.sort(grant.access_rights)}
      end)
      |> Enum.sort()

    assert grants_after_failure == grants_before_failure
  end

  test "threads with unavailable roots remain listed and their replies are readable", %{
    conn: conn
  } do
    room_id = "abcdefghijklmnopqrstuvwx12"
    root_id = "missing-provider-root"

    {child, endpoint} =
      OpenAIStub.server(
        fn request, _body ->
          assert request.method == "GET"
          assert request.request_path == "/v1/api/v4/posts/#{root_id}"
          {404, %{}}
        end,
        self()
      )

    start_supervised!(child)

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Missing root connector",
        provider: "mattermost",
        kind: "retrieval",
        url: endpoint,
        token: "test-token",
        settings: %{"jido_chat" => %{"bot_user_id" => "bot-1"}}
      })
      |> Zaq.Repo.insert!()

    {:ok, person} = People.create_person(%{full_name: "Thread participant"})

    {:ok, facts} =
      Facts.for_capture(%{
        provider: "mattermost",
        channel_config_id: config.id,
        channel_id: room_id,
        kind: :channel,
        actor_person_id: person.id,
        thread_id: root_id
      })

    {:ok, reply} =
      Conversations.capture_canonical_message(
        facts,
        %{
          role: "external",
          content: "Reply without local root",
          external_message_id: "rootless-reply"
        },
        %{provider: "mattermost", channel_config_id: config.id, provenance: "provider_event"}
      )

    transcript = Zaq.Repo.get!(Zaq.Engine.Conversations.Transcript, reply.transcript_id)
    assert transcript.parent_id
    {:ok, view, _} = live(conn, ~p"/bo/channels/history?channel=#{transcript.parent_id}")
    assert has_element?(view, "#transcript-#{transcript.id}", "Root message unavailable")

    {:ok, detail_view, _} =
      view
      |> element("#transcript-#{transcript.id} a[href='/bo/channels/history/#{transcript.id}']")
      |> render_click()
      |> follow_redirect(conn, ~p"/bo/channels/history/#{transcript.id}")

    assert has_element?(
             detail_view,
             "#history-message-#{reply.message_id}",
             "Reply without local root"
           )

    assert_receive {:openai_request, "GET", "/v1/api/v4/posts/" <> ^root_id, "", _}
  end

  defp shared_history_fixture(url, room_id) do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Refresh fixture #{room_id}",
        provider: "mattermost",
        kind: "retrieval",
        url: url,
        token: "test-token"
      })
      |> Zaq.Repo.insert!()

    {:ok, person} = People.create_person(%{full_name: "Refresh member #{room_id}"})

    {:ok, _} =
      People.add_channel(%{
        person_id: person.id,
        platform: "mattermost",
        channel_identifier: "alex",
        channel_config_id: config.id
      })

    captured =
      Incoming.new(%{
        content: "Refresh fixture message",
        channel_id: room_id,
        provider: :mattermost,
        author_id: "alex",
        message_id: "refresh-#{room_id}",
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })
      |> HistoryIngress.capture()
      |> then(fn {:ok, result} -> result end)

    {config, person, captured}
  end
end
