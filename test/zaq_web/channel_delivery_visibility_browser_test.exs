defmodule ZaqWeb.ChannelDeliveryVisibilityBrowserTest do
  use ZaqWeb.ConnCase, async: false

  @moduletag :real_browser

  import Mox
  import Zaq.AccountsFixtures
  import Zaq.ChannelDeliveryFixtures

  alias Zaq.Accounts
  alias Zaq.Channels.{Api, Bridge, JidoChatBridge}
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.ChannelHistoryUpdates
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, MessageDelivery, TranscriptMessage}
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.Repo
  alias Zaq.TestSupport.{HistoryBrowser, OpenAIStub}

  setup :verify_on_exit!

  defmodule TimeoutTransport do
    def bridge_for(_provider), do: __MODULE__
    defdelegate fetch_connection_details_for_config(config), to: Bridge
    def send_reply(_outgoing, _connection), do: {:error, :timeout}
  end

  for engine <- ~w(chromium firefox webkit) do
    @tag browser_engine: engine, timeout: 180_000
    test "#{engine}: outstanding delivery visibility survives failure recovery and lost UI hints" do
      set_mox_global()
      Zaq.DataCase.isolate_event_registry()
      admin = login_user(super_admin_fixture())
      staff = login_user(user_fixture())
      fixture = measured_answer()
      other = stored_channel_answer(config: fixture.config, room: "unrelated")
      status = start_supervised!({Agent, fn -> 403 end})
      {child, endpoint} = provider_server(status)
      start_supervised!(child)

      config =
        fixture.config
        |> ChannelConfig.changeset(%{url: String.trim_trailing(endpoint, "/v1")})
        |> Repo.update!()

      fixture = %{fixture | config: config}
      context = %{fixture: fixture, other: other, admin: admin, staff: staff, status: status}

      HistoryBrowser.run!(
        %{
          runner: "test/e2e/support/channel-delivery-visibility-browser.cjs",
          engine: unquote(engine),
          username: admin.username,
          staff_username: staff.username,
          transcript_id: fixture.captured.transcript_id,
          answer_id: fixture.answer.id,
          input_id: fixture.input.id,
          other_transcript_id: other.captured.transcript_id,
          other_answer_id: other.answer.id
        },
        &checkpoint(&1, context, &2)
      )
    end
  end

  defp checkpoint("reject", ctx, state) do
    result = deliver(ctx.fixture)
    assert {:error, {403, _}} = result.response
    answer = Repo.get!(Message, ctx.fixture.answer.id)
    assert answer.metadata["delivery_observation"]["outcome"] == "failed"
    refute inspect(answer.metadata) =~ "PRIVATE_PROVIDER_DETAIL"
    refute Repo.get_by(TranscriptMessage, message_id: answer.id)
    {%{}, state}
  end

  defp checkpoint("timeout", ctx, state) do
    result = deliver(ctx.fixture, bridge_module: TimeoutTransport)
    assert {:error, :timeout} = result.response

    assert Repo.get!(Message, ctx.fixture.answer.id).metadata["delivery_observation"]["outcome"] ==
             "unconfirmed"

    {%{}, state}
  end

  defp checkpoint("incoming", ctx, state) do
    late =
      stored_channel_answer(
        config: ctx.fixture.config,
        person: ctx.fixture.person,
        private_execution: true
      )

    {%{input_id: late.input.id, answer_id: late.answer.id}, Map.put(state, :late, late)}
  end

  defp checkpoint("lost-hint", ctx, state) do
    expect(Zaq.NodeRouterMock, :dispatch, fn event -> event end)

    assert {:ok, :recorded} =
             MessageDelivery.record(observation(ctx.fixture),
               history_updates_node_router: Zaq.NodeRouterMock
             )

    assert Repo.get!(Message, ctx.fixture.answer.id).metadata["delivery_observation"]["outcome"] ==
             "failed"

    {%{}, state}
  end

  defp checkpoint("confirm", ctx, state) do
    id = record_confirmation(ctx)
    assert id == ctx.fixture.answer.id
    refute Repo.get_by(TranscriptMessage, message_id: id)
    {%{}, state}
  end

  defp checkpoint("associate", ctx, state) do
    assert {:ok, _} = HistoryIngress.associate_confirmation(ctx.fixture.answer.id)
    assert Repo.get_by!(TranscriptMessage, message_id: ctx.fixture.answer.id)
    {%{}, state}
  end

  defp checkpoint("duplicate-hint", ctx, state) do
    assert :ok = ChannelHistoryUpdates.publish([ctx.fixture.answer.id])
    {%{}, state}
  end

  defp checkpoint("pages", ctx, state) do
    pages =
      for _ <- 1..51 do
        stored_channel_answer(
          config: ctx.fixture.config,
          person: ctx.fixture.person,
          private_execution: true,
          room: "pages"
        )
      end

    last = List.last(pages)

    {%{transcript_id: last.captured.transcript_id, answer_id: last.answer.id},
     Map.put(state, :page_answer, last)}
  end

  defp checkpoint("page-associate", ctx, state) do
    page_context = %{ctx | fixture: state.page_answer}
    id = record_confirmation(page_context)
    assert {:ok, _} = HistoryIngress.associate_confirmation(id)
    {%{}, state}
  end

  defp checkpoint("revoke", ctx, state) do
    ctx.admin |> Ecto.Changeset.change(role_id: ctx.staff.role_id) |> Repo.update!()
    assert {:ok, :recorded} = MessageDelivery.record(observation(state.late))
    {%{}, state}
  end

  defp measured_answer do
    stored_channel_answer(
      private_execution: true,
      trace: [%{"type" => "tool_call", "name" => "lookup_policy", "response" => "PRIVATE_TRACE"}],
      result: %{
        agent: "Visibility Agent",
        model: "fixture-model",
        prompt_tokens: 120,
        completion_tokens: 30,
        total_tokens: 150,
        measurements: %{llm_calls: 2, tool_calls: 1}
      }
    )
  end

  defp provider_server(status) do
    OpenAIStub.server(
      fn _conn, body ->
        case Agent.get(status, & &1) do
          403 -> {403, %{"message" => "PRIVATE_PROVIDER_DETAIL"}}
          201 -> {201, %{"id" => "accepted-#{Ecto.UUID.generate()}", "message" => body}}
        end
      end,
      self()
    )
  end

  defp record_confirmation(ctx) do
    Agent.update(ctx.status, fn _ -> 201 end)
    outgoing = outgoing(ctx.fixture)
    connection = Bridge.fetch_connection_details_for_config(ctx.fixture.config)

    assert {:ok, %{confirmation: :confirmed} = receipt} =
             JidoChatBridge.send_reply(outgoing, connection)

    assert {:ok, id} =
             HistoryIngress.record_confirmation(%{
               confirmation: :confirmed,
               kind: :channel,
               provider: ctx.fixture.config.provider,
               channel_config_id: ctx.fixture.config.id,
               channel_id: outgoing.channel_id,
               message_id: receipt.message_id,
               user_message_id: ctx.fixture.input.id,
               assistant_message_id: ctx.fixture.answer.id
             })

    id
  end

  defp deliver(fixture, opts \\ []) do
    Event.new(outgoing(fixture), :channels, opts: Keyword.put(opts, :action, :deliver_outgoing))
    |> then(&Api.handle_event(&1, :deliver_outgoing, nil))
  end

  defp outgoing(fixture) do
    %Outgoing{
      body: fixture.answer.content,
      channel_id: channel_id(fixture),
      provider: :mattermost,
      routing_context: %{channel_config_id: fixture.config.id, conversation_type: :room},
      metadata: %{
        user_message_id: fixture.input.id,
        assistant_message_id: fixture.answer.id,
        persisted_assistant_message_id: fixture.answer.id
      }
    }
  end

  defp channel_id(fixture),
    do: Conversations.get_conversation(fixture.input.conversation_id).external_channel_id

  defp observation(fixture) do
    %{
      user_message_id: fixture.input.id,
      assistant_message_id: fixture.answer.id,
      channel_config_id: fixture.config.id,
      outcome: :failed,
      reason: :rejected,
      provider_code: 403
    }
  end

  defp login_user(user) do
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    user
  end
end
