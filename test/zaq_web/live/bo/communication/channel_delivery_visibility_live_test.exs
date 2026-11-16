defmodule ZaqWeb.Live.BO.Communication.ChannelDeliveryVisibilityLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.ChannelDeliveryFixtures

  alias Zaq.Accounts
  alias Zaq.Accounts.People
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.ChannelHistoryUpdates
  alias Zaq.Engine.Conversations.Message
  alias Zaq.Engine.Conversations.MessageDelivery
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Repo
  alias Zaq.TestSupport.OpenAIStub

  setup :verify_on_exit!

  setup %{conn: conn} do
    stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      Zaq.NodeRouter.dispatch(event, %{
        async_start_fn: fn fun ->
          fun.()
          {:ok, self()}
        end
      })
    end)

    admin = super_admin_fixture()
    {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})

    fixture = stored_channel_answer(history_updates_node_router: Zaq.NodeRouterMock)

    Phoenix.PubSub.subscribe(
      Zaq.PubSub,
      ChannelHistoryUpdates.topic(fixture.captured.transcript_id)
    )

    fixture
    |> Map.put(:admin, admin)
    |> Map.put(:conn, init_test_session(conn, %{user_id: admin.id}))
  end

  test "outstanding answers are inline bubbles after canonical messages with accessible details",
       ctx do
    {:ok, view, html} = live(ctx.conn, path(ctx))

    assert has_element?(
             view,
             "#history-message-#{ctx.answer.id} [data-delivery-state='unconfirmed']"
           )

    assert html =~ "Stored answer"
    assert html =~ "Delivery unconfirmed"

    ids =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[id^='history-message-']")
      |> LazyHTML.attribute("id")

    assert ids == ["history-message-#{ctx.input.id}", "history-message-#{ctx.answer.id}"]

    view
    |> element("#history-message-#{ctx.answer.id} [data-testid='delivery-status']")
    |> render_click()

    assert has_element?(view, "#channel-delivery-details[role='dialog']")
    assert render(view) =~ "may have been delivered"
    refute has_element?(view, "[phx-click='retry_sending']")
    refute has_element?(view, "[phx-click='cancel_message']")
  end

  test "failed private-answer information displays persisted agent model and measurements", ctx do
    fixture =
      stored_channel_answer(
        config: ctx.config,
        private_execution: true,
        room: "measured-private",
        result: %{
          agent: "Support Agent",
          model: "fixture-model",
          prompt_tokens: 120,
          completion_tokens: 30,
          total_tokens: 150,
          measurements: %{llm_calls: 2, tool_calls: 1}
        }
      )

    assert {:ok, :recorded} = MessageDelivery.record(observation(fixture))
    {:ok, view, _} = live(ctx.conn, path(fixture))

    view
    |> element("#history-message-#{fixture.answer.id} [phx-click='open_message_info']")
    |> render_click()

    assert has_element?(view, "[data-testid='message-info-popin']", "Support Agent")
    assert has_element?(view, "[data-testid='message-info-popin']", "fixture-model")

    measurements =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-testid='message-info-popin'] span")
      |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))
      |> Enum.chunk_every(2)

    for {key, value} <- [
          {"prompt_tokens", "120"},
          {"completion_tokens", "30"},
          {"total_tokens", "150"},
          {"llm_calls", "2"},
          {"tool_calls", "1"}
        ] do
      assert [key, value] in measurements
    end

    refute has_element?(view, "[data-testid='message-info-popin']", "not provided")
  end

  test "committed evidence updates only the scoped bubble and preserves its open details", ctx do
    {:ok, view, _} = live(ctx.conn, path(ctx))
    view |> element("[data-testid='delivery-status']") |> render_click()
    assert {:ok, :recorded} = MessageDelivery.record(observation(ctx))
    flush_committed_update(view, ctx)

    assert has_element?(view, "#history-message-#{ctx.answer.id} [data-delivery-state='failed']")
    assert has_element?(view, "#history-message-#{ctx.input.id}")
    assert has_element?(view, "#channel-delivery-details")
    assert render(view) =~ "The provider rejected the delivery."
  end

  test "failed stored answers retain the existing information icon and private trace modal",
       ctx do
    private =
      stored_channel_answer(
        config: ctx.config,
        room: "private-room",
        private_execution: true,
        trace: [%{"type" => "tool_call", "name" => "add", "response" => "PRIVATE_TOOL"}]
      )

    assert {:ok, :recorded} = MessageDelivery.record(observation(private))
    {:ok, view, html} = live(ctx.conn, path(private))
    refute html =~ "PRIVATE_TOOL"

    assert has_element?(
             view,
             "#history-message-#{private.answer.id} [data-testid='delivery-status']"
           )

    view
    |> element("#history-message-#{private.answer.id} [phx-click='open_message_info']")
    |> render_click()

    assert render(view) =~ "add"
    view |> element("[data-testid^='trace-row-']") |> render_click()
    assert render(view) =~ "PRIVATE_TOOL"
  end

  test "association replaces the provisional status on the same answer UUID without duplication",
       ctx do
    {:ok, view, _} = live(ctx.conn, path(ctx))

    assert {:ok, _} =
             HistoryIngress.capture_confirmed(%{
               confirmation: :confirmed,
               kind: :channel,
               provider: ctx.config.provider,
               channel_config_id: ctx.config.id,
               channel_id: "room",
               message_id: "sent-post",
               user_message_id: ctx.input.id,
               assistant_message_id: ctx.answer.id
             })

    html = flush_committed_update(view, ctx)
    assert has_element?(view, "#history-message-#{ctx.answer.id}")
    refute has_element?(view, "#history-message-#{ctx.answer.id} [data-delivery-state]")

    assert html
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#history-message-#{ctx.answer.id}")
           |> Enum.count() == 1
  end

  test "confirmed association replaces failed evidence while delivery details remain open", ctx do
    {:ok, view, _} = live(ctx.conn, path(ctx))

    view
    |> element("#history-message-#{ctx.answer.id} [data-testid='delivery-status']")
    |> render_click()

    assert {:ok, :recorded} = MessageDelivery.record(observation(ctx))
    flush_committed_update(view, ctx)
    assert has_element?(view, "#channel-delivery-details")
    assert render(view) =~ "The provider rejected the delivery."

    confirm_answer(ctx)
    html = flush_committed_update(view, ctx)

    assert has_element?(view, "#channel-delivery-details")
    assert html =~ "Delivery confirmed"
    assert has_element?(view, "#channel-delivery-details", "The provider confirmed delivery.")
    refute has_element?(view, "#history-message-#{ctx.answer.id} [data-delivery-state]")

    assert Enum.count(
             LazyHTML.query(LazyHTML.from_fragment(html), "#history-message-#{ctx.answer.id}")
           ) ==
             1

    view
    |> element("#channel-delivery-details button[phx-click='close_delivery_info']", "Close")
    |> render_click()

    refute has_element?(view, "#channel-delivery-details")

    {:ok, reopened, html} = live(ctx.conn, path(ctx))
    refute html =~ "data-delivery-state"

    assert Enum.count(
             LazyHTML.query(LazyHTML.from_fragment(html), "#history-message-#{ctx.answer.id}")
           ) ==
             1

    reopened
    |> element("#history-message-#{ctx.answer.id} [phx-click='open_message_info']")
    |> render_click()

    assert has_element?(reopened, "[data-testid='message-info-popin']")

    ids =
      render(reopened)
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#history-message-#{ctx.answer.id}")

    assert Enum.count(ids) == 1
  end

  test "opening delivery details after role revocation clears private history", ctx do
    private =
      stored_channel_answer(
        config: ctx.config,
        room: "room",
        private_execution: true,
        trace: [%{"type" => "tool_call", "name" => "lookup", "response" => "PRIVATE_OPEN_TRACE"}]
      )

    {:ok, view, _} = live(ctx.conn, path(private))

    view
    |> element("#history-message-#{private.answer.id} [phx-click='open_message_info']")
    |> render_click()

    view |> element("[data-testid^='trace-row-']") |> render_click()

    view
    |> element("#history-message-#{private.answer.id} [data-testid='delivery-status']")
    |> render_click()

    assert render(view) =~ "PRIVATE_OPEN_TRACE"
    assert has_element?(view, "#channel-delivery-details")

    staff = user_fixture()
    ctx.admin |> Ecto.Changeset.change(role_id: staff.role_id) |> Repo.update!()
    render_hook(view, "open_delivery_info", %{"id" => private.answer.id})

    assert render(view) =~ "Not authorized"
    refute has_element?(view, "#channel-delivery-details")
    refute has_element?(view, "[data-testid='message-info-popin']")
    refute has_element?(view, "[id^='history-message-']")
    refute has_element?(view, "[data-testid='message-info-popin']")
    refute render(view) =~ "PRIVATE_OPEN_TRACE"

    send(
      view.pid,
      {:channel_history_updated, private.captured.transcript_id, [private.answer.id]}
    )

    html = flush_updates(view)
    assert html =~ "Not authorized"
    refute has_element?(view, "[id^='history-message-']")
    refute has_element?(view, "#channel-delivery-details")
    refute has_element?(view, "[data-testid='message-info-popin']")
    refute html =~ "PRIVATE_OPEN_TRACE"
  end

  test "loading another pending page after role revocation clears private history", ctx do
    private =
      stored_channel_answer(
        config: ctx.config,
        room: "private-paging-room",
        private_execution: true,
        trace: [%{"type" => "tool_call", "name" => "lookup", "response" => "PRIVATE_PAGE_TRACE"}]
      )

    for _ <- 1..50 do
      stored_channel_answer(
        config: ctx.config,
        room: "private-paging-room",
        person: private.person,
        private_execution: true
      )
    end

    {:ok, view, _} = live(ctx.conn, path(private))

    view
    |> element("#history-message-#{private.answer.id} [phx-click='open_message_info']")
    |> render_click()

    view |> element("[data-testid^='trace-row-']") |> render_click()

    view
    |> element("#history-message-#{private.answer.id} [data-testid='delivery-status']")
    |> render_click()

    assert render(view) =~ "PRIVATE_PAGE_TRACE"
    assert has_element?(view, "#channel-delivery-details")
    assert has_element?(view, "button", "Load more outstanding messages")

    staff = user_fixture()
    ctx.admin |> Ecto.Changeset.change(role_id: staff.role_id) |> Repo.update!()
    render_hook(view, "load_pending", %{})

    assert render(view) =~ "Not authorized"
    refute has_element?(view, "#channel-delivery-details")
    refute has_element?(view, "[data-testid='message-info-popin']")
    refute has_element?(view, "[id^='history-message-']")
    refute has_element?(view, "[data-testid='message-info-popin']")
    refute render(view) =~ "PRIVATE_PAGE_TRACE"

    send(
      view.pid,
      {:channel_history_updated, private.captured.transcript_id, [private.answer.id]}
    )

    html = flush_updates(view)
    assert html =~ "Not authorized"
    refute has_element?(view, "[id^='history-message-']")
    refute has_element?(view, "#channel-delivery-details")
    refute has_element?(view, "[data-testid='message-info-popin']")
    refute html =~ "PRIVATE_PAGE_TRACE"
  end

  test "a lost UI notification affects freshness only and reopening reads the committed evidence",
       ctx do
    {:ok, view, _} = live(ctx.conn, path(ctx))
    expect(Zaq.NodeRouterMock, :dispatch, fn _ -> raise "broadcast unavailable" end)

    assert {:ok, :recorded} =
             MessageDelivery.record(observation(ctx),
               history_updates_node_router: Zaq.NodeRouterMock
             )

    assert has_element?(view, "[data-delivery-state='unconfirmed']")
    {:ok, reopened, _} = live(ctx.conn, path(ctx))
    assert has_element?(reopened, "[data-delivery-state='failed']")
  end

  test "foreign notifications cannot expose a different transcript's answer", ctx do
    {:ok, view, _} = live(ctx.conn, path(ctx))
    other = stored_channel_answer(config: ctx.config, room: "other-room")
    send(view.pid, {:channel_history_updated, ctx.captured.transcript_id, [other.answer.id]})
    flush_updates(view)
    refute has_element?(view, "#history-message-#{other.answer.id}")
    assert has_element?(view, "#history-message-#{ctx.answer.id}")
  end

  test "live updates retain explicitly loaded pending pages", ctx do
    for _ <- 1..50, do: stored_channel_answer(config: ctx.config)
    {:ok, view, _} = live(ctx.conn, path(ctx))
    assert has_element?(view, "button", "Load more outstanding messages")
    view |> element("button", "Load more outstanding messages") |> render_click()

    before = pending_count(render(view))
    assert before == 51
    assert {:ok, :recorded} = MessageDelivery.record(observation(ctx))
    html = flush_committed_update(view, ctx)
    assert pending_count(html) == before
    assert has_element?(view, "#history-message-#{ctx.answer.id} [data-delivery-state='failed']")
  end

  test "off-page delivery hints do not bypass pending load-more", ctx do
    others = for _ <- 1..50, do: stored_channel_answer(config: ctx.config)
    last = List.last(others)
    {:ok, view, _} = live(ctx.conn, path(ctx))
    assert pending_count(render(view)) == 50
    refute has_element?(view, "#history-message-#{last.answer.id}")

    assert {:ok, :recorded} = MessageDelivery.record(observation(last))
    html = flush_committed_update(view, last)
    assert pending_count(html) == 50
    refute has_element?(view, "#history-message-#{last.answer.id}")

    view |> element("button", "Load more outstanding messages") |> render_click()
    assert pending_count(render(view)) == 51
    assert has_element?(view, "#history-message-#{last.answer.id} [data-delivery-state='failed']")
    refute has_element?(view, "button", "Load more outstanding messages")
  end

  test "one bounded invalidation updates all 51 persisted answers across pending pages", ctx do
    additional = for _ <- 1..50, do: stored_channel_answer(config: ctx.config, room: "room")
    fixtures = [ctx | additional]
    {:ok, view, _} = live(ctx.conn, path(ctx))
    assert pending_count(render(view)) == 50

    expect(Zaq.NodeRouterMock, :dispatch, 51, fn event ->
      send(self(), {:intercepted_history_publication, event})
      event
    end)

    for fixture <- fixtures do
      assert {:ok, :recorded} =
               MessageDelivery.record(observation(fixture),
                 history_updates_node_router: Zaq.NodeRouterMock
               )
    end

    answer_ids = Enum.map(fixtures, & &1.answer.id)
    assert Enum.uniq(answer_ids) == answer_ids

    for id <- answer_ids do
      assert %Message{metadata: %{"delivery_observation" => %{"outcome" => "failed"}}} =
               Repo.get!(Message, id)
    end

    publications =
      for _ <- answer_ids do
        assert_receive {:intercepted_history_publication, event}
        event
      end

    published_ids =
      Enum.flat_map(publications, fn event ->
        assert %Zaq.Event{
                 request:
                   {:broadcast, topic, {:channel_history_updated, transcript_id, message_ids}},
                 opts: [action: :broadcast, confidential: true]
               } = event

        assert topic == ChannelHistoryUpdates.topic(ctx.captured.transcript_id)
        assert transcript_id == ctx.captured.transcript_id
        message_ids
      end)

    assert Enum.sort(published_ids) == Enum.sort(answer_ids)

    hint =
      {:channel_history_updated, ctx.captured.transcript_id,
       answer_ids ++ [hd(answer_ids), nil, 123]}

    send(view.pid, hint)
    html = flush_updates(view)

    assert pending_count(html) == 50

    assert Enum.all?(Enum.take(answer_ids, 50), fn id ->
             has_element?(view, "#history-message-#{id} [data-delivery-state='failed']")
           end)

    refute has_element?(view, "#history-message-#{List.last(answer_ids)}")

    view |> element("button", "Load more outstanding messages") |> render_click()
    html = render(view)
    assert pending_count(html) == 51

    assert Enum.all?(answer_ids, fn id ->
             has_element?(view, "#history-message-#{id} [data-delivery-state='failed']")
           end)

    rendered_ids =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[id^='history-message-']")
      |> LazyHTML.attribute("id")

    for id <- answer_ids do
      assert Enum.count(rendered_ids, &(&1 == "history-message-#{id}")) == 1
    end

    refute has_element?(view, "button", "Load more outstanding messages")
    send(view.pid, hint)
    replayed = flush_updates(view)
    assert pending_count(replayed) == 51

    assert Enum.all?(answer_ids, fn id ->
             has_element?(view, "#history-message-#{id} [data-delivery-state='failed']")
           end)

    replayed_ids =
      replayed
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[id^='history-message-']")
      |> LazyHTML.attribute("id")

    for id <- answer_ids,
        do: assert(Enum.count(replayed_ids, &(&1 == "history-message-#{id}")) == 1)

    render_hook(view, "load_pending", %{})
    exhausted = render(view)
    assert pending_count(exhausted) == 51

    assert Enum.all?(answer_ids, fn id ->
             has_element?(view, "#history-message-#{id} [data-delivery-state='failed']")
           end)

    exhausted_ids =
      exhausted
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[id^='history-message-']")
      |> LazyHTML.attribute("id")

    for id <- answer_ids,
        do: assert(Enum.count(exhausted_ids, &(&1 == "history-message-#{id}")) == 1)

    refute has_element?(view, "button", "Load more outstanding messages")
  end

  test "rating changes only its canonical row and retains loaded outstanding pages", ctx do
    delivered = stored_channel_answer(config: ctx.config)
    confirm_answer(delivered)
    {view, _last} = load_outstanding_pages(ctx)

    view
    |> element("#history-message-#{ctx.answer.id} [data-testid='delivery-status']")
    |> render_click()

    view
    |> element("#history-message-#{delivered.answer.id} button[phx-value-type='positive']")
    |> render_click()

    assert pending_count(render(view)) == 51
    assert has_element?(view, "#channel-delivery-details")

    assert has_element?(
             view,
             "#history-message-#{delivered.answer.id} [data-reaction-type='positive'][aria-pressed='true']",
             "1"
           )

    refute has_element?(view, "button", "Load more outstanding messages")
  end

  test "grant and revoke retain loaded pending pages and the current canonical page", ctx do
    {view, last} = load_outstanding_pages(ctx, after: 50)
    {:ok, reader} = People.create_person(%{full_name: "Additional history reader"})
    assert has_element?(view, "#history-message-#{last.input.id}")
    refute has_element?(view, "#history-message-#{ctx.input.id}")

    view
    |> element("#history-message-#{ctx.answer.id} [data-testid='delivery-status']")
    |> render_click()

    view |> element("button[phx-click='open_access']") |> render_click()

    view
    |> form("#manual-channel-history-grant", grant: %{person_id: reader.id})
    |> render_submit()

    assert pending_count(render(view)) == 51
    assert has_element?(view, "#channel-delivery-details")
    assert has_element?(view, "#history-message-#{last.input.id}")
    refute has_element?(view, "#history-message-#{ctx.input.id}")
    assert has_element?(view, "#channel-access-grants", "Person #{reader.id}")

    view |> element("button[phx-click='revoke'][phx-value-id='#{reader.id}']") |> render_click()

    assert pending_count(render(view)) == 51
    assert has_element?(view, "#channel-delivery-details")
    assert has_element?(view, "#history-message-#{last.input.id}")
    refute has_element?(view, "#history-message-#{ctx.input.id}")
    refute has_element?(view, "#channel-access-grants", "Person #{reader.id}")
    refute has_element?(view, "button", "Load more outstanding messages")
  end

  test "provider membership refresh retains both loaded windows", ctx do
    room = "abcdefghijklmnopqrstuvwx12"

    {_server, endpoint} =
      OpenAIStub.start!(
        fn request, _body ->
          assert request.request_path == "/api/v4/channels/#{room}/members"
          {200, []}
        end,
        self()
      )

    config =
      ctx.config
      |> ChannelConfig.changeset(%{url: String.trim_trailing(endpoint, "/v1")})
      |> Repo.update!()

    fixture = stored_channel_answer(config: config, room: room)
    ctx = Map.merge(ctx, fixture)
    {view, last} = load_outstanding_pages(ctx, room: room, after: 50)
    view |> element("button[phx-click='open_access']") |> render_click()
    view |> element("button[phx-click='refresh']") |> render_click()

    assert render(view) =~ "Provider access refreshed (0 linked People)"
    assert pending_count(render(view)) == 51
    assert has_element?(view, "#history-message-#{last.input.id}")
    refute has_element?(view, "#history-message-#{fixture.input.id}")
    refute has_element?(view, "button", "Load more outstanding messages")
    assert_receive {:openai_request, "GET", "/api/v4/channels/" <> ^room <> "/members", _, _}
  end

  for event <- ["feedback", "grant", "revoke", "refresh", "open_message_info"] do
    test "#{event} clears private information and history after role revocation", ctx do
      private =
        stored_channel_answer(
          config: ctx.config,
          room: "abcdefghijklmnopqrstuvwx12",
          private_execution: true,
          trace: [
            %{"type" => "tool_call", "name" => "lookup", "response" => "PRIVATE_REVOKED_TRACE"}
          ]
        )

      {:ok, view, _} = live(ctx.conn, path(private))
      view |> element("[phx-click='open_message_info']") |> render_click()
      view |> element("[data-testid^='trace-row-']") |> render_click()
      assert render(view) =~ "PRIVATE_REVOKED_TRACE"

      staff = user_fixture()
      ctx.admin |> Ecto.Changeset.change(role_id: staff.role_id) |> Repo.update!()

      id = if unquote(event) == "revoke", do: to_string(ctx.person.id), else: private.answer.id

      render_hook(view, unquote(event), %{
        "id" => id,
        "type" => "positive",
        "grant" => %{"person_id" => to_string(ctx.person.id)}
      })

      assert render(view) =~ "Not authorized"
      refute render(view) =~ "PRIVATE_REVOKED_TRACE"
      refute has_element?(view, "[id^='history-message-']")
      refute has_element?(view, "[data-testid='message-info-popin']")
    end
  end

  test "navigating transcripts ignores notifications from the previous subscription", ctx do
    other = stored_channel_answer(config: ctx.config, room: "other-room")
    {:ok, view, _} = live(ctx.conn, path(ctx))
    render_patch(view, path(other))
    assert {:ok, :recorded} = MessageDelivery.record(observation(ctx))
    flush_committed_update(view, ctx)

    refute has_element?(view, "#history-message-#{ctx.answer.id}")
    assert has_element?(view, "#history-message-#{other.answer.id}")
  end

  test "a fresh role revocation clears the displayed data on the next invalidation", ctx do
    {:ok, view, _} = live(ctx.conn, path(ctx))
    staff = user_fixture()
    ctx.admin |> Ecto.Changeset.change(role_id: staff.role_id) |> Repo.update!()
    assert {:ok, :recorded} = MessageDelivery.record(observation(ctx))
    html = flush_committed_update(view, ctx)
    assert html =~ "Not authorized"
    refute has_element?(view, "#history-message-#{ctx.answer.id}")
    refute has_element?(view, "#channel-delivery-details")
  end

  defp pending_count(html),
    do:
      html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-delivery-state]") |> Enum.count()

  defp load_outstanding_pages(ctx, opts \\ []) do
    others =
      for _ <- 1..50,
          do: stored_channel_answer(config: ctx.config, room: Keyword.get(opts, :room, "room"))

    {:ok, view, _} = live(ctx.conn, path(ctx) <> "?after=#{Keyword.get(opts, :after, 0)}")
    assert pending_count(render(view)) == 50
    view |> element("button", "Load more outstanding messages") |> render_click()
    assert pending_count(render(view)) == 51
    {view, List.last(others)}
  end

  defp confirm_answer(fixture) do
    assert {:ok, _} =
             HistoryIngress.capture_confirmed(%{
               confirmation: :confirmed,
               kind: :channel,
               provider: fixture.config.provider,
               channel_config_id: fixture.config.id,
               channel_id: "room",
               message_id: "delivered-#{fixture.answer.id}",
               user_message_id: fixture.input.id,
               assistant_message_id: fixture.answer.id
             })
  end

  defp flush_updates(view) do
    send(view.pid, :flush_history_updates)
    render(view)
  end

  defp flush_committed_update(view, ctx) do
    id = ctx.captured.transcript_id
    answer_id = ctx.answer.id
    assert_receive notification = {:channel_history_updated, ^id, [^answer_id]}
    # Replaying an observed hint also exercises idempotence after the domain call committed.
    send(view.pid, notification)
    flush_updates(view)
  end

  defp path(ctx), do: ~p"/bo/channels/history/#{ctx.captured.transcript_id}"

  defp observation(ctx) do
    %{
      user_message_id: ctx.input.id,
      assistant_message_id: ctx.answer.id,
      channel_config_id: ctx.config.id,
      outcome: :failed,
      reason: :rejected
    }
  end
end
