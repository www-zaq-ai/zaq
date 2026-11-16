defmodule Zaq.Engine.Conversations.AnswerOwnershipTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  import Zaq.AccountsFixtures
  import Zaq.ChannelDeliveryFixtures

  alias Zaq.Accounts.People
  alias Zaq.Engine.Api
  alias Zaq.Engine.Conversations

  alias Zaq.Engine.Conversations.{
    AnswerOwnership,
    ExecutionRecord,
    Message,
    ToolHistory,
    TranscriptMessage
  }

  alias Zaq.Engine.HistoryIngress
  alias Zaq.Event
  alias Zaq.QueryRecorder

  setup do
    fixture =
      stored_channel_answer(
        private_execution: true,
        trace: [
          %{"type" => "tool_call", "name" => "lookup_policy", "response" => "PRIVATE_EVIDENCE"}
        ]
      )

    Map.put(
      fixture,
      :execution,
      Repo.get_by!(ExecutionRecord, public_answer_message_id: fixture.answer.id)
    )
  end

  test "owned roots and tool history use exact execution references without reply metadata",
       ctx do
    metadata = Map.delete(ctx.answer.metadata, "in_reply_to_message_id")
    answer = ctx.answer |> Message.confirmation_changeset(metadata) |> Repo.update!()

    assert ctx.answer.id in answer_ids(AnswerOwnership.conversation_pairs_query())
    assert execution_ids(AnswerOwnership.owned_root_executions_query()) == [ctx.execution.id]
    assert [shown] = ToolHistory.present([answer], :full)
    assert shown.trace == ctx.execution.trace_entries
  end

  test "raw root lookup preserves an invalid owner instead of reporting absent evidence", ctx do
    {:ok, other} = People.create_person(%{full_name: "Other owner"})
    assert {:ok, _} = Conversations.update_execution_owner(ctx.execution, other.id)

    assert execution_ids(AnswerOwnership.root_executions_query()) == [ctx.execution.id]
    assert execution_ids(AnswerOwnership.owned_root_executions_query()) == []
    assert [shown] = ToolHistory.present([ctx.answer], :full)
    assert shown.trace == []
  end

  property "reply metadata cannot rebind execution-backed tool evidence", ctx do
    check all(reply <- string(:alphanumeric, max_length: 80), max_runs: 15) do
      metadata = Map.put(ctx.answer.metadata, "in_reply_to_message_id", reply)
      answer = ctx.answer |> Message.confirmation_changeset(metadata) |> Repo.update!()

      assert execution_ids(AnswerOwnership.owned_root_executions_query()) == [ctx.execution.id]
      assert [shown] = ToolHistory.present([answer], :full)
      assert shown.trace == ctx.execution.trace_entries
    end
  end

  for {target, changes} <- [
        {:input, %{role: "assistant"}},
        {:answer, %{role: "user"}},
        {:input, :other_conversation},
        {:answer, :other_conversation}
      ] do
    test "owned roots reject #{target} relationship mismatch #{inspect(changes)}", ctx do
      other = stored_channel_answer(config: ctx.config, room: "other-conversation")

      changes =
        case unquote(Macro.escape(changes)) do
          :other_conversation -> %{conversation_id: other.input.conversation_id}
          attrs -> attrs
        end

      ctx |> Map.fetch!(unquote(target)) |> Message.changeset(changes) |> Repo.update!()

      refute ctx.execution.id in execution_ids(AnswerOwnership.owned_root_executions_query())
    end
  end

  test "legacy conversation pairs exist without an owned root execution", ctx do
    legacy = stored_channel_answer(config: ctx.config, room: "legacy")
    assert legacy.answer.id in answer_ids(AnswerOwnership.conversation_pairs_query())
    refute legacy.answer.id in answer_ids(AnswerOwnership.owned_root_executions_query())
  end

  test "input receipts are not root executions", ctx do
    conversation = Conversations.get_conversation(ctx.input.conversation_id)

    {:ok, input} =
      Conversations.add_message(conversation, %{role: "user", content: "Unconsumed input"})

    receipt =
      %ExecutionRecord{}
      |> ExecutionRecord.changeset(%{
        person_id: ctx.person.id,
        user_message_id: input.id,
        root_execution_id: ctx.execution.id,
        status: "unconsumed",
        finalization_token_hash: Base.encode64(:crypto.strong_rand_bytes(32))
      })
      |> Repo.insert!()

    refute receipt.id in execution_ids(AnswerOwnership.root_executions_query())
    assert execution_ids(AnswerOwnership.owned_root_executions_query()) == [ctx.execution.id]
  end

  test "tool history still resolves an entire conversation or canonical batch in one query",
       ctx do
    other =
      stored_channel_answer(
        config: ctx.config,
        person: ctx.person,
        private_execution: true,
        trace: [%{"type" => "tool_call", "name" => "other", "response" => "OTHER_EVIDENCE"}]
      )

    {[first, second], queries} =
      QueryRecorder.capture(fn -> ToolHistory.present([ctx.answer, other.answer], :full) end)

    assert length(queries) == 1
    assert first.trace == ctx.execution.trace_entries
    assert inspect(second.trace) =~ "OTHER_EVIDENCE"

    associate(ctx)
    associate(other)

    rows =
      Enum.map([ctx.answer, other.answer], &%{message_id: &1.id, role: "assistant"})

    {projected, queries} =
      QueryRecorder.capture(fn ->
        ToolHistory.present_canonical(rows, ctx.captured.transcript_id)
      end)

    assert length(queries) == 1
    assert length(projected) == 2
    refute inspect(projected) =~ "PRIVATE_EVIDENCE"
    refute inspect(projected) =~ "OTHER_EVIDENCE"
  end

  test "canonical conversation-less roots require both placements but do not permit private inspection",
       ctx do
    associate(ctx)
    detach_conversations(ctx)

    query = AnswerOwnership.canonical_root_executions_query(ctx.captured.transcript_id)
    assert execution_ids(query) == [ctx.execution.id]
    assert execution_ids(AnswerOwnership.owned_root_executions_query()) == []
    assert {:error, :not_found} = information(ctx)

    placement =
      Repo.get_by!(TranscriptMessage,
        transcript_id: ctx.captured.transcript_id,
        message_id: ctx.answer.id
      )

    Repo.delete!(placement)
    assert execution_ids(query) == []
  end

  test "canonical roots without an input placement remain ineligible", ctx do
    associate(ctx)
    detach_conversations(ctx)

    ctx.captured.transcript_id
    |> then(&Repo.get_by!(TranscriptMessage, transcript_id: &1, message_id: ctx.input.id))
    |> Repo.delete!()

    query = AnswerOwnership.canonical_root_executions_query(ctx.captured.transcript_id)
    assert execution_ids(query) == []
  end

  test "canonical roots with a conversation still reject a mismatched execution owner", ctx do
    associate(ctx)
    {:ok, other} = People.create_person(%{full_name: "Other owner"})
    assert {:ok, _} = Conversations.update_execution_owner(ctx.execution, other.id)

    query = AnswerOwnership.canonical_root_executions_query(ctx.captured.transcript_id)
    assert execution_ids(query) == []
  end

  defp execution_ids(query), do: query |> select([execution: e], e.id) |> Repo.all()
  defp answer_ids(query), do: query |> select([answer: a], a.id) |> Repo.all()

  defp associate(ctx) do
    assert {:ok, _} =
             HistoryIngress.capture_confirmed(%{
               confirmation: :confirmed,
               kind: :channel,
               provider: ctx.config.provider,
               channel_config_id: ctx.config.id,
               channel_id: "room",
               message_id: "ownership-answer-#{ctx.answer.id}",
               user_message_id: ctx.input.id,
               assistant_message_id: ctx.answer.id
             })
  end

  defp detach_conversations(ctx) do
    for message <- [ctx.input, Repo.get!(Message, ctx.answer.id)] do
      message |> Ecto.Changeset.change(conversation_id: nil) |> Repo.update!()
    end
  end

  defp information(ctx) do
    admin = super_admin_fixture()

    Event.new(
      %{op: :message_info, id: ctx.captured.transcript_id, message_id: ctx.answer.id},
      :engine,
      actor: %{user_id: admin.id},
      opts: [action: :channel_history_admin, confidential: true]
    )
    |> then(&Api.handle_event(&1, :channel_history_admin, nil))
    |> Map.fetch!(:response)
  end
end
