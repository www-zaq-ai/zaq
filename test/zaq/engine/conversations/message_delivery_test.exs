defmodule Zaq.Engine.Conversations.MessageDeliveryTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Mox

  alias Zaq.Accounts.People
  alias Zaq.Channels.Api, as: ChannelsApi
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.ChannelHistoryUpdates
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, MessageDelivery, TranscriptMessage}
  alias Zaq.Engine.History.Facts
  alias Zaq.Engine.Messages.Incoming
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

    {:ok, person} = People.create_person(%{"full_name" => "Delivery reader"})

    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Delivery evidence",
        provider: "mattermost",
        kind: "retrieval",
        url: "https://example.invalid",
        token: "fixture-token"
      })
      |> Repo.insert!()

    {:ok, captured} =
      Conversations.capture_canonical_message(
        %Facts{
          provider: config.provider,
          channel_config_id: config.id,
          channel_id: "room",
          kind: :channel,
          actor_person_id: person.id
        },
        %{
          role: "external",
          content: "Question",
          author_id: "sender",
          external_message_id: "input"
        },
        %{
          provider: config.provider,
          channel_config_id: config.id,
          provenance: "channel_adapter"
        }
      )

    incoming =
      Incoming.new(%{
        content: "Question",
        channel_id: "room",
        provider: :mattermost,
        author_id: "sender",
        message_id: "input",
        routing_context: %{channel_config_id: config.id, conversation_type: :room}
      })
      |> CommunicationBridge.put_conversation_identity()

    {:ok, binding} = Conversations.admit_incoming(incoming)

    {:ok, %{assistant_message_id: answer_id}} =
      Conversations.finalize_incoming(
        binding.user_message_id,
        binding.finalization_token,
        %{answer: "Stored answer", agent: "Support", error: false},
        history_updates_node_router: Zaq.NodeRouterMock
      )

    input = Repo.get!(Message, binding.user_message_id)
    answer = Repo.get!(Message, answer_id)

    request = %{
      user_message_id: input.id,
      assistant_message_id: answer.id,
      channel_config_id: config.id,
      outcome: :failed,
      reason: :rejected
    }

    %{
      input: input,
      answer: answer,
      request: request,
      captured: captured,
      binding: binding,
      config: config
    }
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
end
