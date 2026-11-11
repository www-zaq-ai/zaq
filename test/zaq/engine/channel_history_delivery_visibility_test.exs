defmodule Zaq.Engine.ChannelHistoryDeliveryVisibilityTest do
  use Zaq.DataCase, async: true

  import Zaq.AccountsFixtures
  import Zaq.ChannelDeliveryFixtures

  alias Zaq.Engine.Api
  alias Zaq.Engine.Conversations.{ExecutionRecord, Message, MessageDelivery, TranscriptMessage}
  alias Zaq.Engine.HistoryIngress
  alias Zaq.Event

  setup do
    stored_channel_answer() |> Map.put(:admin, super_admin_fixture())
  end

  test "unconfirmed stored answers are visible only in the additive BO projection", ctx do
    assert {:ok, detail} = request(ctx.admin, %{op: :detail, id: ctx.captured.transcript_id})
    assert Enum.map(detail.messages, & &1.message_id) == [ctx.input.id]

    assert [%{message_id: id, content: "Stored answer", delivery: %{state: :unconfirmed}}] =
             detail.pending_messages

    assert id == ctx.answer.id
    refute Map.has_key?(hd(detail.pending_messages), :metadata)
    refute Map.has_key?(hd(detail.pending_messages), :trace)
    refute Repo.get_by(TranscriptMessage, message_id: id)
  end

  test "failed answers retain stored agent model and measurements for privileged inspection",
       ctx do
    for private? <- [false, true] do
      result = %{
        agent: "Support Agent",
        model: "fixture-model",
        prompt_tokens: 120,
        completion_tokens: 30,
        total_tokens: 150,
        latency_ms: 1250,
        measurements: %{llm_calls: 2, tool_calls: 1}
      }

      fixture =
        stored_channel_answer(
          config: ctx.config,
          room: "measured-#{private?}",
          private_execution: private?,
          result: result
        )

      info = %{
        op: :message_info,
        id: fixture.captured.transcript_id,
        message_id: fixture.answer.id
      }

      assert {:ok, before_failure} = request(ctx.admin, info)
      assert {:ok, :recorded} = MessageDelivery.record(observation(fixture, :failed, :rejected))
      assert {:ok, projected} = request(ctx.admin, info)

      assert projected.metadata["agent"] == "Support Agent"
      assert projected.model == "fixture-model"
      assert projected.prompt_tokens == 120
      assert projected.completion_tokens == 30
      assert projected.total_tokens == 150
      assert projected.latency_ms == 1250
      assert projected.metadata["measurements"] == %{"llm_calls" => 2, "tool_calls" => 1}
      assert Map.drop(projected, [:metadata]) == Map.drop(before_failure, [:metadata])
      assert projected.metadata["measurements"] == before_failure.metadata["measurements"]
      refute Repo.get_by(TranscriptMessage, message_id: fixture.answer.id)

      if private? do
        assert Repo.get!(Message, fixture.answer.id).total_tokens == nil
        refute Repo.get!(Message, fixture.answer.id).metadata["measurements"]
      end
    end
  end

  test "subscribing requires current Engine authorization and returns no message data", ctx do
    req = %{op: :subscription, id: ctx.captured.transcript_id}
    assert {:ok, %{topic: topic} = subscription} = request(ctx.admin, req)
    assert topic == "bo:channel_history:#{ctx.captured.transcript_id}"
    assert map_size(subscription) == 1
    assert {:error, :unauthorized} = request(user_fixture(), req)
  end

  test "failed private answers retain privileged information and traces without gaining placement",
       ctx do
    private =
      stored_channel_answer(
        config: ctx.config,
        room: "private-room",
        private_execution: true,
        trace: [%{"type" => "tool_call", "name" => "add", "response" => "PRIVATE_TOOL"}]
      )

    assert {:ok, :recorded} = MessageDelivery.record(observation(private, :failed, :rejected))
    info = %{op: :message_info, id: private.captured.transcript_id, message_id: private.answer.id}
    execution = Repo.get_by!(ExecutionRecord, public_answer_message_id: private.answer.id)
    assert {:ok, projected} = request(ctx.admin, info)
    assert projected.trace == execution.trace_entries
    assert inspect(projected.trace) =~ "PRIVATE_TOOL"
    assert Repo.get!(Message, private.answer.id).trace == []
    refute Repo.get_by(TranscriptMessage, message_id: private.answer.id)
    assert {:error, :unauthorized} = request(user_fixture(), info)
    assert {:error, :not_found} = request(ctx.admin, %{info | id: ctx.captured.transcript_id})

    assert {:ok, detail} = request(ctx.admin, %{op: :detail, id: private.captured.transcript_id})
    refute inspect(detail.pending_messages) =~ "PRIVATE_TOOL"

    execution |> Ecto.Changeset.change(person_id: ctx.person.id) |> Repo.update!()
    assert {:error, :not_found} = request(ctx.admin, info)
  end

  test "recorded failure and timeout are distinguished without read-side mutation", ctx do
    before = Repo.aggregate(TranscriptMessage, :count)
    assert {:ok, :recorded} = MessageDelivery.record(observation(ctx, :failed, :rejected))

    assert {:ok, %{pending_messages: [%{delivery: %{state: :failed}}]}} =
             request(ctx.admin, %{op: :detail, id: ctx.captured.transcript_id})

    assert {:ok, :recorded} = MessageDelivery.record(observation(ctx, :unconfirmed, :timeout))

    assert {:ok, %{pending_messages: [%{delivery: %{state: :unconfirmed, reason: reason}}]}} =
             request(ctx.admin, %{op: :detail, id: ctx.captured.transcript_id})

    assert reason =~ "may have accepted"
    assert Repo.aggregate(TranscriptMessage, :count) == before
  end

  test "an invalid existing root cannot use completed legacy metadata as a fallback", ctx do
    private =
      stored_channel_answer(config: ctx.config, room: "invalid-root", private_execution: true)

    execution = Repo.get_by!(ExecutionRecord, public_answer_message_id: private.answer.id)
    execution |> ExecutionRecord.owner_changeset(ctx.person.id) |> Repo.update!()

    private.input
    |> Message.confirmation_changeset(
      Map.put(private.input.metadata, "execution_status", "completed")
    )
    |> Repo.update!()

    assert {:ok, %{pending_messages: []}} =
             request(ctx.admin, %{op: :detail, id: private.captured.transcript_id})

    assert {:error, :invalid_delivery_scope} =
             MessageDelivery.record(observation(private, :failed, :rejected))

    assert {:error, :not_found} =
             request(ctx.admin, %{
               op: :message_info,
               id: private.captured.transcript_id,
               message_id: private.answer.id
             })
  end

  test "legacy eligibility requires recorded completion", ctx do
    ctx.input
    |> Message.confirmation_changeset(Map.delete(ctx.input.metadata, "execution_status"))
    |> Repo.update!()

    assert {:ok, %{pending_messages: []}} =
             request(ctx.admin, %{op: :detail, id: ctx.captured.transcript_id})

    assert {:error, :invalid_delivery_scope} =
             MessageDelivery.record(observation(ctx, :failed, :rejected))
  end

  test "a pending raw input root also blocks legacy fallback", ctx do
    %ExecutionRecord{}
    |> ExecutionRecord.changeset(%{
      person_id: ctx.person.id,
      user_message_id: ctx.input.id,
      status: "pending",
      finalization_token_hash: Base.encode64(:crypto.strong_rand_bytes(32))
    })
    |> Repo.insert!()

    assert {:ok, %{pending_messages: []}} =
             request(ctx.admin, %{op: :detail, id: ctx.captured.transcript_id})

    assert {:error, :invalid_delivery_scope} =
             MessageDelivery.record(observation(ctx, :failed, :rejected))
  end

  test "delivery eligibility still requires the exact metadata reply link", ctx do
    private =
      stored_channel_answer(config: ctx.config, room: "no-reply-link", private_execution: true)

    private.answer
    |> Message.confirmation_changeset(
      Map.delete(private.answer.metadata, "in_reply_to_message_id")
    )
    |> Repo.update!()

    assert {:ok, %{pending_messages: []}} =
             request(ctx.admin, %{op: :detail, id: private.captured.transcript_id})

    assert {:error, :invalid_delivery_scope} =
             MessageDelivery.record(observation(private, :failed, :rejected))
  end

  test "delayed association is shown only in the exact confirmation target and then deduplicates",
       ctx do
    delivery = confirmation(ctx)
    assert {:ok, id} = HistoryIngress.record_confirmation(delivery)

    assert {:ok, %{pending_messages: [%{delivery: %{state: :history_updating}}]}} =
             request(ctx.admin, %{op: :detail, id: ctx.captured.transcript_id})

    assert {:ok, _} = HistoryIngress.associate_confirmation(id)

    assert {:ok, %{messages: messages, pending_messages: []}} =
             request(ctx.admin, %{op: :detail, id: ctx.captured.transcript_id})

    assert Enum.map(messages, & &1.message_id) == [ctx.input.id, ctx.answer.id]
  end

  test "confirmed elsewhere is removed from origin pending rows", ctx do
    metadata =
      ctx.answer.metadata
      |> Map.put("delivery_confirmation", %{"message_id" => "accepted"})
      |> Map.put("history_association", %{"transcript_ids" => [Ecto.UUID.generate()]})

    ctx.answer |> Message.confirmation_changeset(metadata) |> Repo.update!()

    assert {:ok, %{pending_messages: []}} =
             request(ctx.admin, %{op: :detail, id: ctx.captured.transcript_id})
  end

  test "changed-row reads are bounded, freshly authorized and scoped to the exact transcript",
       ctx do
    other = stored_channel_answer(config: ctx.config, room: "other-room")

    req = %{
      op: :message_changes,
      id: ctx.captured.transcript_id,
      message_ids: [ctx.answer.id, other.answer.id]
    }

    assert {:ok, changes} = request(ctx.admin, req)
    assert Enum.map(changes.pending_messages, & &1.message_id) == [ctx.answer.id]
    assert changes.removed_ids == [other.answer.id]
    assert {:error, :unauthorized} = request(user_fixture(), req)

    assert {:error, :invalid_request} =
             request(ctx.admin, %{req | message_ids: List.duplicate(ctx.answer.id, 51)})

    assert {:error, :invalid_request} = request(ctx.admin, %{req | message_ids: ["invalid"]})
  end

  test "pending pagination is stable and independent from the canonical cursor", ctx do
    for _ <- 1..50, do: stored_channel_answer(config: ctx.config)
    assert {:ok, first} = request(ctx.admin, %{op: :detail, id: ctx.captured.transcript_id})
    assert length(first.messages) == 50
    assert length(first.pending_messages) == 50
    assert first.pending_has_more

    assert {:ok, second} =
             request(ctx.admin, %{
               op: :detail,
               id: ctx.captured.transcript_id,
               cursor: first.next_cursor,
               pending_cursor: first.pending_next_cursor
             })

    assert length(second.messages) == 1
    assert length(second.pending_messages) == 1

    refute hd(second.pending_messages).message_id in Enum.map(
             first.pending_messages,
             & &1.message_id
           )

    refute second.pending_has_more
  end

  test "each pending row supplies a continuation usable after a loaded-window trim", ctx do
    later = stored_channel_answer(config: ctx.config)
    assert {:ok, detail} = request(ctx.admin, %{op: :detail, id: ctx.captured.transcript_id})
    [first, last] = detail.pending_messages
    assert first.message_id == ctx.answer.id
    assert last.message_id == later.answer.id
    assert last.pending_cursor == detail.pending_next_cursor

    assert {:ok, page} =
             request(ctx.admin, %{
               op: :detail,
               id: ctx.captured.transcript_id,
               pending_cursor: first.pending_cursor
             })

    assert Enum.map(page.pending_messages, & &1.message_id) == [later.answer.id]
    assert page.messages == detail.messages
  end

  defp observation(ctx, outcome, reason) do
    %{
      user_message_id: ctx.input.id,
      assistant_message_id: ctx.answer.id,
      channel_config_id: ctx.config.id,
      outcome: outcome,
      reason: reason
    }
  end

  defp confirmation(ctx) do
    %{
      confirmation: :confirmed,
      kind: :channel,
      provider: ctx.config.provider,
      channel_config_id: ctx.config.id,
      channel_id: "room",
      message_id: "provider-answer",
      user_message_id: ctx.input.id,
      assistant_message_id: ctx.answer.id
    }
  end

  defp request(user, req) do
    Event.new(req, :engine,
      actor: %{user_id: user.id},
      opts: [action: :channel_history_admin, confidential: true]
    )
    |> then(&Api.handle_event(&1, :channel_history_admin, nil))
    |> Map.fetch!(:response)
  end
end
