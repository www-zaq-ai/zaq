defmodule Zaq.Engine.Conversations.MessageDeliveryTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Mox
  import Zaq.ChannelDeliveryFixtures

  alias Zaq.Channels.Api, as: ChannelsApi
  alias Zaq.Channels.DeliveryConfirmation
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.ChannelHistoryUpdates
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, MessageDelivery, TranscriptMessage}
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.TestSupport.OpenAIStub

  setup :verify_on_exit!

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn event ->
      Zaq.NodeRouter.dispatch(event, %{
        async_start_fn: fn fun ->
          fun.()
          {:ok, self()}
        end
      })
    end)

    fixture =
      stored_channel_answer(
        message_id: "input",
        result: %{agent: "Support"},
        history_updates_node_router: Zaq.NodeRouterMock
      )

    request = %{
      user_message_id: fixture.input.id,
      assistant_message_id: fixture.answer.id,
      channel_config_id: fixture.config.id,
      outcome: :failed,
      reason: :rejected
    }

    Map.put(fixture, :request, request)
  end

  test "records bounded private evidence without transcript placement", ctx do
    assert {:ok, :recorded} = MessageDelivery.record(ctx.request)
    answer = Repo.get!(Message, ctx.answer.id)
    assert answer.metadata["in_reply_to_message_id"] == ctx.input.id
    assert answer.metadata["delivery_observation"]["outcome"] == "failed"
    assert answer.metadata["delivery_observation"]["reason_code"] == "rejected"
    refute Repo.get_by(TranscriptMessage, message_id: answer.id)

    assert {:ok, :unchanged} = MessageDelivery.record(ctx.request)
    assert Repo.get!(Message, answer.id).metadata == answer.metadata
  end

  test "reporter table preserves errors and stores only bounded evidence", _ctx do
    cases = [
      %{
        name: :two_tuple,
        response: {:error, :transport},
        expected: %{"outcome" => "unconfirmed", "reason_code" => "unknown"}
      },
      %{
        name: :three_tuple,
        response: {:error, :transport, :details},
        expected: %{"outcome" => "unconfirmed", "reason_code" => "unknown"}
      },
      %{
        name: :normalized_rejection,
        response: {:error, :rejected, :details},
        observation: %{outcome: :failed, reason: :rejected, provider_code: 403},
        expected: %{"outcome" => "failed", "reason_code" => "rejected", "provider_code" => 403}
      },
      %{
        name: :malformed_facts,
        response: {:error, :malformed},
        observation: %{outcome: :failed, reason: "private response", provider_code: -1},
        expected: %{"outcome" => "unconfirmed", "reason_code" => "unknown"}
      },
      %{
        name: :missing_persisted_answer,
        response: {:error, :nil_answer},
        observation: %{outcome: :failed, reason: :rejected},
        missing_answer: true
      }
    ]

    for %{response: response} = scenario <- cases do
      ctx = stored_channel_answer()
      persisted_id = if scenario[:missing_answer], do: nil, else: ctx.answer.id
      outgoing = reporter_outgoing(ctx, persisted_id)

      if scenario[:missing_answer] do
        outgoing = %{
          outgoing
          | metadata: Map.put(outgoing.metadata, :assistant_message_id, ctx.answer.id)
        }

        result = reporter_record(scenario, outgoing)
        assert result == response
        unchanged = Repo.get!(Message, ctx.answer.id)
        assert unchanged.content == ctx.answer.content
        assert unchanged.metadata == ctx.answer.metadata
        refute Repo.get_by(TranscriptMessage, message_id: ctx.answer.id)
      else
        assert reporter_record(scenario, outgoing) == response, inspect(scenario.name)

        stored = Repo.get!(Message, ctx.answer.id)
        assert stored.content == ctx.answer.content
        evidence = stored.metadata["delivery_observation"]
        observed_at = evidence["observed_at"]
        assert {:ok, _, _} = DateTime.from_iso8601(observed_at)

        assert Map.drop(evidence, ["observed_at"]) ==
                 Map.merge(%{"version" => 1, "provider_code" => nil}, scenario.expected)

        refute Repo.get_by(TranscriptMessage, message_id: ctx.answer.id)
      end
    end
  end

  defp reporter_record(scenario, outgoing) do
    case scenario do
      %{observation: observation} ->
        DeliveryConfirmation.record(scenario.response, outgoing, observation, [])

      _ ->
        DeliveryConfirmation.record(scenario.response, outgoing, [])
    end
  end

  test "real HTTP delivery stays single-send when Engine recording raises or throws" do
    rows = [
      %{
        name: :accepted,
        status: 201,
        body: %{"id" => "post-accepted"},
        action: :record_delivery_confirmation,
        failure: :raise
      },
      %{
        name: :rejected_raise,
        status: 403,
        body: %{"message" => "private provider response"},
        action: :record_delivery_observation,
        failure: :raise
      },
      %{
        name: :rejected_throw,
        status: 403,
        body: %{"message" => "private provider response"},
        action: :record_delivery_observation,
        failure: :throw
      }
    ]

    for %{name: name, status: status, body: response_body, action: action, failure: failure} <-
          rows do
      ctx = stored_channel_answer()

      {child, endpoint} =
        OpenAIStub.server(fn _conn, _body -> {status, response_body} end, self())

      start_supervised!(Supervisor.child_spec(child, id: {:delivery_recording_http, name}))

      ctx.config
      |> ChannelConfig.changeset(%{url: String.trim_trailing(endpoint, "/v1")})
      |> Repo.update!()

      expect(Zaq.NodeRouterMock, :dispatch, fn event ->
        send(self(), {:recording_attempt, name, event})

        case failure do
          :raise -> raise "Engine recording unavailable"
          :throw -> throw(:engine_recording_unavailable)
        end
      end)

      outgoing = reporter_outgoing(ctx, ctx.answer.id)

      event =
        Event.new(outgoing, :channels,
          opts: [action: :deliver_outgoing, delivery_node_router: Zaq.NodeRouterMock]
        )

      result = ChannelsApi.handle_event(event, :deliver_outgoing, nil).response

      assert_receive {:openai_request, "POST", "/api/v4/posts", "", request_body}

      assert Jason.decode!(request_body) == %{
               "channel_id" => "room",
               "message" => ctx.answer.content
             }

      refute_received {:openai_request, _, _, _, _}
      assert_receive {:recording_attempt, ^name, %Event{opts: opts} = recording_event}
      assert opts[:action] == action
      if action == :record_delivery_observation, do: assert(opts[:confidential])

      stored = Repo.get!(Message, ctx.answer.id)
      assert stored.content == ctx.answer.content
      refute Repo.get_by(TranscriptMessage, message_id: ctx.answer.id)

      case name do
        :accepted ->
          assert {:ok,
                  %{
                    confirmation: :confirmed,
                    message_id: "post-accepted",
                    confirmation_recording: :unavailable
                  }} = result

          assert recording_event.request.receipt.message_id == "post-accepted"

        _ ->
          assert result == {:error, {403, response_body}}
          refute stored.metadata["delivery_observation"]
          refute inspect(stored.metadata) =~ "private provider response"
      end
    end
  end

  test "the delivery fixture retains its provider input identity and stored agent", ctx do
    assert ctx.input.external_message_id == "input"
    assert ctx.answer.metadata["agent"] == "Support"
    assert ctx.answer.metadata["in_reply_to_message_id"] == ctx.input.id
    assert ctx.input.role == "user"
    assert ctx.answer.role == "assistant"
    refute Repo.get_by(TranscriptMessage, message_id: ctx.answer.id)
  end

  test "rejects wrong input, connector, missing answer and unbounded evidence", ctx do
    for changes <- [
          %{user_message_id: Ecto.UUID.generate()},
          %{assistant_message_id: Ecto.UUID.generate()},
          %{assistant_message_id: "not-a-uuid"},
          %{channel_config_id: ctx.request.channel_config_id + 1},
          %{outcome: :sent},
          %{provider_code: "raw private response"},
          %{reason: "secret raw provider response"}
        ] do
      assert {:error, _} = MessageDelivery.record(Map.merge(ctx.request, changes))
    end

    refute Repo.get!(Message, ctx.answer.id).metadata["delivery_observation"]
  end

  test "confirmation dominates late failure observations without losing metadata", ctx do
    receipt = %{"provider" => "mattermost", "message_id" => "post"}

    ctx.answer
    |> Message.confirmation_changeset(
      Map.put(ctx.answer.metadata, "delivery_confirmation", receipt)
    )
    |> Repo.update!()

    assert {:ok, :confirmed} = MessageDelivery.record(ctx.request)
    stored = Repo.get!(Message, ctx.answer.id)
    assert stored.metadata["delivery_confirmation"] == receipt
    refute stored.metadata["delivery_observation"]
  end

  test "outer rollback discards evidence even when the nested write succeeds", ctx do
    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, :recorded} = MessageDelivery.record(ctx.request)
               Repo.rollback(:abort)
             end)

    refute Repo.get!(Message, ctx.answer.id).metadata["delivery_observation"]
  end

  test "scoped broadcasts contain IDs only and never run inside the owner's transaction", ctx do
    id = ctx.captured.transcript_id
    answer_id = ctx.answer.id
    Phoenix.PubSub.subscribe(Zaq.PubSub, ChannelHistoryUpdates.topic(id))

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert :ok = ChannelHistoryUpdates.publish([ctx.answer.id])
               refute_received {:channel_history_updated, _, [^answer_id]}
               Repo.rollback(:abort)
             end)

    assert :ok = ChannelHistoryUpdates.publish([ctx.answer.id])
    assert_receive {:channel_history_updated, ^id, [^answer_id]}
  end

  test "origin and fixed target notifications do not create transcript memberships", ctx do
    target = Ecto.UUID.generate()

    ctx.answer
    |> Message.confirmation_changeset(
      Map.put(ctx.answer.metadata, "history_association", %{"transcript_ids" => [target]})
    )
    |> Repo.update!()

    scopes = ChannelHistoryUpdates.affected_scopes([ctx.answer.id])
    assert scopes[ctx.captured.transcript_id] == [ctx.answer.id]
    assert scopes[target] == [ctx.answer.id]
    refute Repo.get_by(TranscriptMessage, message_id: ctx.answer.id)
  end

  test "a failed UI dispatch never loses recorded evidence or changes the domain result", ctx do
    expect(Zaq.NodeRouterMock, :dispatch, fn _ -> raise "UI broadcaster unavailable" end)

    assert {:ok, :recorded} =
             MessageDelivery.record(ctx.request, history_updates_node_router: Zaq.NodeRouterMock)

    assert Repo.get!(Message, ctx.answer.id).metadata["delivery_observation"]["outcome"] ==
             "failed"

    refute Repo.get_by(TranscriptMessage, message_id: ctx.answer.id)
  end

  test "finalization publishes from the committed owner without private content", ctx do
    expect(Zaq.NodeRouterMock, :dispatch, fn event ->
      refute Repo.in_transaction?()
      assert event.next_hop.type == :async
      assert event.opts[:confidential]
      assert {:broadcast, _, {:channel_history_updated, id, [answer_id]}} = event.request
      assert id == ctx.captured.transcript_id
      assert answer_id == ctx.answer.id
      event
    end)

    assert {:ok, %{assistant_message_id: id}} =
             Conversations.finalize_incoming(
               ctx.binding.user_message_id,
               ctx.binding.finalization_token,
               %{answer: "Stored answer", error: false},
               history_updates_node_router: Zaq.NodeRouterMock
             )

    assert id == ctx.answer.id
    refute Repo.get_by(TranscriptMessage, message_id: id)
  end

  test "real adapter HTTP rejection persists evidence through Channels and Engine without a browser",
       ctx do
    {child, endpoint} =
      OpenAIStub.server(
        fn _conn, _body -> {403, %{"message" => "private provider response"}} end,
        self()
      )

    start_supervised!(child)

    ctx.config
    |> ChannelConfig.changeset(%{url: String.trim_trailing(endpoint, "/v1")})
    |> Repo.update!()

    outgoing = %Outgoing{
      provider: :mattermost,
      channel_id: "room",
      body: ctx.answer.content,
      routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room},
      metadata: %{
        user_message_id: ctx.input.id,
        assistant_message_id: ctx.answer.id,
        persisted_assistant_message_id: ctx.answer.id
      }
    }

    result =
      Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])
      |> then(&ChannelsApi.handle_event(&1, :deliver_outgoing, nil))

    assert {:error, {403, _}} = result.response
    stored = Repo.get!(Message, ctx.answer.id)
    assert stored.content == ctx.answer.content
    assert stored.metadata["delivery_observation"]["outcome"] == "failed"
    assert stored.metadata["delivery_observation"]["provider_code"] == 403
    refute inspect(stored.metadata) =~ "private provider response"
    refute Repo.get_by(TranscriptMessage, message_id: ctx.answer.id)
  end

  property "confirmation always dominates the display status of observations" do
    check all(
            outcome <- member_of(["failed", "unconfirmed"]),
            reason <- string(:alphanumeric, max_length: 100)
          ) do
      message = %Message{
        metadata: %{
          "delivery_confirmation" => %{"message_id" => "confirmed"},
          "delivery_observation" => %{
            "outcome" => outcome,
            "reason_code" => reason,
            "provider_code" => 403
          }
        }
      }

      assert MessageDelivery.presentation(message).state == :history_updating
      assert MessageDelivery.presentation(message).provider_code == nil
    end
  end

  for reason <- [:channel_disabled, :channel_archived] do
    test "Channels records #{reason} without calling the provider", ctx do
      {child, endpoint} =
        OpenAIStub.server(fn _conn, _body -> {500, %{}} end, self())

      start_supervised!(child)

      ctx.config
      |> ChannelConfig.changeset(%{url: String.trim_trailing(endpoint, "/v1")})
      |> Repo.update!()

      if unquote(reason) == :channel_archived do
        assert {:ok, _} = ChannelConfig.archive(Repo.get!(ChannelConfig, ctx.config.id))
      else
        ctx.config |> ChannelConfig.changeset(%{enabled: false}) |> Repo.update!()
      end

      outgoing = %Outgoing{
        provider: :mattermost,
        channel_id: "room",
        body: ctx.answer.content,
        routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room},
        metadata: %{
          user_message_id: ctx.input.id,
          assistant_message_id: ctx.answer.id,
          persisted_assistant_message_id: ctx.answer.id
        }
      }

      event = Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])

      assert %{response: {:error, unquote(reason)}} =
               ChannelsApi.handle_event(event, :deliver_outgoing, nil)

      stored = Repo.get!(Message, ctx.answer.id)
      assert stored.metadata["delivery_observation"]["outcome"] == "failed"
      assert stored.metadata["delivery_observation"]["reason_code"] == "missing_configuration"
      assert stored.content == ctx.answer.content
      refute Repo.get_by(TranscriptMessage, message_id: stored.id)
      refute_received {:openai_request, _, _, _, _}
    end
  end

  defp reporter_outgoing(ctx, persisted_id) do
    %Outgoing{
      provider: :mattermost,
      channel_id: "room",
      body: ctx.answer.content,
      routing_context: %{channel_config_id: ctx.config.id, conversation_type: :room},
      metadata: %{
        user_message_id: ctx.input.id,
        assistant_message_id: ctx.answer.id,
        persisted_assistant_message_id: persisted_id
      }
    }
  end
end
