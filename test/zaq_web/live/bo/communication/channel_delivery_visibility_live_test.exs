defmodule ZaqWeb.Live.BO.Communication.ChannelDeliveryVisibilityLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  import Zaq.ChannelDeliveryFixtures

  alias Zaq.Accounts
  alias Zaq.Engine.ChannelHistoryUpdates
  alias Zaq.Engine.Conversations.MessageDelivery
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Repo

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
