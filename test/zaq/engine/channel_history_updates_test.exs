defmodule Zaq.Engine.ChannelHistoryUpdatesTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties
  use Oban.Testing, repo: Zaq.Repo

  import Mox
  import Zaq.ChannelDeliveryFixtures

  alias Zaq.Accounts.People
  alias Zaq.Engine.ChannelHistoryUpdates
  alias Zaq.Engine.Conversations.{Message, TranscriptHistory, TranscriptMessage}
  alias Zaq.Engine.{HistoryDeliveryWorker, HistoryIngress}
  alias Zaq.QueryRecorder

  setup :verify_on_exit!

  setup do
    stored_channel_answer(private_execution: true, trace: [%{"response" => "PRIVATE_TRACE"}])
  end

  test "loaded publication shares origin and fixed-target scope resolution without message reads",
       ctx do
    target = Ecto.UUID.generate()

    answer =
      ctx.answer
      |> Message.confirmation_changeset(
        Map.put(ctx.answer.metadata, "history_association", %{"transcript_ids" => [target]})
      )
      |> Repo.update!()

    scopes = ChannelHistoryUpdates.affected_scopes([answer.id])
    assert scopes == %{ctx.captured.transcript_id => [answer.id], target => [answer.id]}
    expect_publications(scopes)

    {:ok, queries} =
      QueryRecorder.capture(fn ->
        ChannelHistoryUpdates.publish_messages([answer],
          history_updates_node_router: Zaq.NodeRouterMock
        )
      end)

    assert Enum.map(queries, & &1.source) == ["transcript_messages"]
    assert_publications(scopes)
    refute Repo.get_by(TranscriptMessage, message_id: answer.id)
  end

  property "duplicate messages and target IDs never duplicate invalidations", ctx do
    targets = [ctx.captured.transcript_id, Ecto.UUID.generate(), Ecto.UUID.generate()]

    check all(
            ids <- list_of(member_of(targets), min_length: 1, max_length: 12),
            copies <- integer(1..4),
            max_runs: 12
          ) do
      answer = %{
        ctx.answer
        | metadata:
            Map.put(ctx.answer.metadata, "history_association", %{"transcript_ids" => ids})
      }

      scopes = Map.new(Enum.uniq([ctx.captured.transcript_id | ids]), &{&1, [answer.id]})
      expect_publications(scopes)

      assert :ok =
               ChannelHistoryUpdates.publish_messages(List.duplicate(answer, copies),
                 history_updates_node_router: Zaq.NodeRouterMock
               )

      assert_publications(scopes)
      refute_received {:history_publication, _, _}
    end
  end

  test "loaded publication suppresses nested notifications and leaves rollback to its owner",
       ctx do
    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, []} =
                        QueryRecorder.capture(fn ->
                          ChannelHistoryUpdates.publish_messages([ctx.answer],
                            history_updates_node_router: Zaq.NodeRouterMock
                          )
                        end)

               Repo.rollback(:abort)
             end)
  end

  for failure <- [:raise, :throw, :exit] do
    test "loaded publication isolates dispatch #{failure}", ctx do
      expect(Zaq.NodeRouterMock, :dispatch, fn _event ->
        case unquote(failure) do
          :raise -> raise "UI unavailable"
          :throw -> throw(:ui_unavailable)
          :exit -> exit(:ui_unavailable)
        end
      end)

      assert :ok =
               ChannelHistoryUpdates.publish_messages([ctx.answer],
                 history_updates_node_router: Zaq.NodeRouterMock
               )

      assert Repo.get!(Message, ctx.answer.id).content == ctx.answer.content
      refute Repo.get_by(TranscriptMessage, message_id: ctx.answer.id)
    end
  end

  test "confirmation and replay invalidate immediately before association, then association invalidates again",
       ctx do
    transcript_id = ctx.captured.transcript_id
    answer_id = ctx.answer.id
    Phoenix.PubSub.subscribe(Zaq.PubSub, ChannelHistoryUpdates.topic(transcript_id))

    for expected_reads <- [2, 1] do
      {{:ok, ^answer_id}, queries} =
        QueryRecorder.capture(fn -> HistoryIngress.record_confirmation(confirmation(ctx)) end)

      assert length(message_reads(queries)) == expected_reads
      assert_receive {:channel_history_updated, ^transcript_id, [^answer_id]}
      refute Repo.get_by(TranscriptMessage, message_id: answer_id)
    end

    assert_enqueued(worker: HistoryDeliveryWorker, args: %{"message_id" => answer_id})
    assert {:ok, :ok} = HistoryIngress.associate_confirmation(answer_id)
    assert_receive {:channel_history_updated, ^transcript_id, [^answer_id]}
    assert Repo.get_by!(TranscriptMessage, message_id: answer_id).transcript_id == transcript_id
  end

  test "association reuses its loaded message without another message read", ctx do
    assert {:ok, id} = HistoryIngress.record_confirmation(confirmation(ctx))
    message = Repo.get!(Message, id)
    ids = message.metadata["history_association"]["transcript_ids"]

    {{:ok, :ok}, queries} =
      QueryRecorder.capture(fn -> TranscriptHistory.associate_prepared(message, ids) end)

    assert message_reads(queries) == []
  end

  test "replicated confirmation replay and association notify every recorded target", ctx do
    recipients = ["first-recipient", "second-recipient"]

    for recipient <- recipients do
      assert {:ok, _} =
               People.find_or_create_from_channel("mattermost", %{
                 channel_id: recipient,
                 channel_config_id: ctx.config.id
               })
    end

    delivery = %{
      confirmation: :confirmed,
      kind: :replicated,
      provider: ctx.config.provider,
      channel_config_id: ctx.config.id,
      channel_id: hd(recipients),
      source_scope: "confirmed-outbound",
      message_id: "replicated-#{ctx.answer.id}",
      content: "Replicated answer",
      audience: %{platform: "mattermost", sender: "bot", recipients: recipients}
    }

    assert {:ok, id} = HistoryIngress.record_confirmation(delivery)
    message = Repo.get!(Message, id)
    targets = message.metadata["history_association"]["transcript_ids"]
    assert length(targets) == 2

    for target <- targets do
      Phoenix.PubSub.subscribe(Zaq.PubSub, ChannelHistoryUpdates.topic(target))
    end

    {{:ok, ^id}, queries} =
      QueryRecorder.capture(fn -> HistoryIngress.record_confirmation(delivery) end)

    assert length(message_reads(queries)) == 1

    for target <- targets do
      assert_receive {:channel_history_updated, ^target, [^id]}
    end

    refute Repo.get_by(TranscriptMessage, message_id: id)
    assert {:ok, :ok} = HistoryIngress.associate_confirmation(id)

    for target <- targets do
      assert_receive {:channel_history_updated, ^target, [^id]}
      assert Repo.get_by!(TranscriptMessage, message_id: id, transcript_id: target)
    end
  end

  test "rolled-back confirmation neither notifies nor retains confirmation evidence", ctx do
    transcript_id = ctx.captured.transcript_id
    answer_id = ctx.answer.id
    Phoenix.PubSub.subscribe(Zaq.PubSub, ChannelHistoryUpdates.topic(transcript_id))

    assert {:error, :abort} =
             Repo.transaction(fn ->
               assert {:ok, ^answer_id} = HistoryIngress.record_confirmation(confirmation(ctx))
               Repo.rollback(:abort)
             end)

    refute_received {:channel_history_updated, ^transcript_id, _}
    refute Repo.get!(Message, answer_id).metadata["delivery_confirmation"]
    refute_enqueued(worker: HistoryDeliveryWorker, args: %{"message_id" => answer_id})
  end

  test "failed association emits no completion notification", ctx do
    assert {:ok, id} = HistoryIngress.record_confirmation(confirmation(ctx))
    message = Repo.get!(Message, id)
    transcript_id = ctx.captured.transcript_id
    Phoenix.PubSub.subscribe(Zaq.PubSub, ChannelHistoryUpdates.topic(transcript_id))

    assert {:error, :source_scope_mismatch} =
             TranscriptHistory.associate_prepared(message, [Ecto.UUID.generate()])

    refute_received {:channel_history_updated, ^transcript_id, _}
    refute Repo.get_by(TranscriptMessage, message_id: id)
  end

  defp expect_publications(scopes) do
    expect(Zaq.NodeRouterMock, :dispatch, map_size(scopes), fn event ->
      refute Repo.in_transaction?()
      assert event.next_hop.type == :async
      assert event.opts[:confidential]

      assert {:broadcast, topic, {:channel_history_updated, transcript_id, message_ids}} =
               event.request

      assert topic == ChannelHistoryUpdates.topic(transcript_id)
      assert scopes[transcript_id] == message_ids
      refute inspect(event) =~ "PRIVATE_TRACE"
      send(self(), {:history_publication, transcript_id, message_ids})
      event
    end)
  end

  defp assert_publications(scopes) do
    for {id, message_ids} <- scopes do
      assert_receive {:history_publication, ^id, ^message_ids}
    end
  end

  defp message_reads(queries),
    do:
      Enum.filter(queries, &(&1.source == "messages" and String.starts_with?(&1.query, "SELECT")))

  defp confirmation(ctx) do
    %{
      confirmation: :confirmed,
      kind: :channel,
      provider: ctx.config.provider,
      channel_config_id: ctx.config.id,
      channel_id: "room",
      message_id: "confirmed-#{ctx.answer.id}",
      user_message_id: ctx.input.id,
      assistant_message_id: ctx.answer.id
    }
  end
end
