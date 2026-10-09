defmodule Zaq.Engine.ConversationsMissedBranchesTest do
  use Zaq.DataCase, async: false
  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Contracts.Record
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, MessageTraceArtifact}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Engine.Telemetry.Buffer
  alias Zaq.Repo

  defp incoming(attrs \\ %{}) do
    defaults = %{
      content: "hello",
      channel_id: "room-#{System.unique_integer([:positive])}",
      author_id: "sender-#{System.unique_integer([:positive])}",
      provider: :mattermost
    }

    defaults
    |> Map.merge(attrs)
    |> Incoming.new()
  end

  defp conversation_attrs(overrides \\ %{}) do
    Map.merge(
      %{channel_type: "bo", channel_user_id: "user-#{System.unique_integer([:positive])}"},
      overrides
    )
  end

  defp channel_config_fixture do
    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "telemetry-test-#{System.unique_integer([:positive])}",
      provider: "mattermost",
      kind: "retrieval",
      url: "https://example.invalid",
      token: "test-token"
    })
    |> Repo.insert!()
  end

  defp admit(msg) do
    msg |> CommunicationBridge.put_conversation_identity() |> Conversations.admit_incoming()
  end

  test "rejects invalid history source without creating a message" do
    before = Repo.aggregate(Message, :count)
    msg = incoming(%{message_id: "bad-source", routing_context: %{source_scope: :invalid}})

    assert {:error, :invalid_history_source} = Conversations.admit_incoming(msg)
    assert Repo.aggregate(Message, :count) == before
  end

  test "unsupported canonical admission source falls back to legacy idempotent admission" do
    msg =
      incoming(%{
        message_id: "legacy-#{System.unique_integer([:positive])}",
        routing_context: %{conversation_type: nil}
      })

    assert {:ok, first} = admit(msg)
    assert first.admitted?
    assert {:ok, replay} = admit(msg)
    refute replay.admitted?
    assert replay.user_message_id == first.user_message_id
  end

  test "missing and empty provider message IDs create separate messages without external IDs" do
    msg = incoming()
    assert {:ok, missing_id} = admit(msg)
    assert {:ok, empty_id} = admit(%{msg | message_id: ""})

    refute missing_id.user_message_id == empty_id.user_message_id

    for id <- [missing_id.user_message_id, empty_id.user_message_id] do
      message = Repo.get!(Message, id)
      refute Map.has_key?(message.metadata, "external_message_id")
    end
  end

  test "whitespace-only admitted content returns its changeset without inserting a message" do
    msg =
      incoming(%{content: "   ", message_id: "whitespace-#{System.unique_integer([:positive])}"})

    before = Repo.aggregate(Message, :count)

    assert {:error, %Ecto.Changeset{} = changeset} = admit(msg)
    assert %{content: [_ | _]} = errors_on(changeset)
    assert Repo.aggregate(Message, :count) == before
  end

  test "invalid finalization arguments leave an admitted message unchanged" do
    assert {:ok, admitted} = admit(incoming())
    original = Repo.get!(Message, admitted.user_message_id)

    assert {:error, :invalid_finalization} =
             Conversations.finalize_incoming(
               admitted.user_message_id,
               admitted.finalization_token,
               nil
             )

    unchanged = Repo.get!(Message, original.id)
    assert unchanged.metadata == original.metadata
    assert unchanged.content == original.content

    assert length(
             Conversations.list_messages(
               Conversations.get_conversation!(admitted.conversation_id)
             )
           ) == 1
  end

  test "finalizing an absent user UUID returns not found" do
    assert {:error, :user_message_not_found} =
             Conversations.finalize_incoming(Ecto.UUID.generate(), Ecto.UUID.generate(), %{})
  end

  test "a persisted user message without pending status cannot be finalized" do
    assert {:ok, admitted} = admit(incoming())
    message = Repo.get!(Message, admitted.user_message_id)
    metadata = Map.delete(message.metadata, "execution_status")
    message |> Ecto.Changeset.change(metadata: metadata) |> Repo.update!()

    assert {:error, :message_not_admitted} =
             Conversations.finalize_incoming(message.id, admitted.finalization_token, %{
               answer: "answer"
             })

    refute Enum.any?(
             Conversations.list_messages(
               Conversations.get_conversation!(admitted.conversation_id)
             ),
             &(&1.role == "assistant")
           )
  end

  test "failed finalization rolls back pending input when artifact record is invalid" do
    assert {:ok, admitted} = admit(incoming())
    original = Repo.get!(Message, admitted.user_message_id)

    artifact = %{
      content: <<1, 2, 3>>,
      name: "bad.bin",
      mime_type: "application/octet-stream",
      record: "not a map",
      tool_call_id: "call-1",
      tool_name: "download"
    }

    assert {:error, changeset} =
             Conversations.finalize_incoming(
               admitted.user_message_id,
               admitted.finalization_token,
               %{
                 error: true,
                 trace_artifacts: [artifact]
               }
             )

    assert %Ecto.Changeset{} = changeset
    unchanged = Repo.get!(Message, original.id)
    assert unchanged.metadata == original.metadata
    assert unchanged.content == original.content
    assert Repo.aggregate(MessageTraceArtifact, :count) == 0

    assert length(
             Conversations.list_messages(
               Conversations.get_conversation!(admitted.conversation_id)
             )
           ) == 1
  end

  test "unknown explicit conversation ID returns not found without writes" do
    msg = incoming(%{metadata: %{conversation_id: Ecto.UUID.generate()}})
    count = Repo.aggregate(Message, :count)

    assert {:error, :conversation_not_found} =
             Conversations.persist_message_history(msg, %{content: "history"})

    assert Repo.aggregate(Message, :count) == count
  end

  test "nil provider persists history in the API conversation group" do
    assert {:ok, %{conversation_id: id, message_id: message_id}} =
             Conversations.persist_message_history(incoming(%{provider: nil}), %{
               role: "user",
               content: "api"
             })

    conversation = Conversations.get_conversation!(id)
    assert conversation.channel_type == "api"
    assert Repo.get!(Message, message_id).conversation_id == id
  end

  test "history persistence keeps normalized attachment metadata and caller metadata" do
    attachment = %Record{
      id: "file-#{System.unique_integer([:positive])}",
      kind: :file,
      name: "file.txt",
      mime_type: "text/plain",
      size: 3,
      content: "abc",
      attributes: %{"provider" => "mattermost"},
      raw: %{secret: "hidden"}
    }

    assert {:ok, %{message_id: id}} =
             Conversations.persist_message_history(incoming(%{attachments: [attachment]}), %{
               content: "history",
               metadata: %{"custom" => "kept"}
             })

    message = Repo.get!(Message, id)
    assert message.metadata["custom"] == "kept"

    assert [%{"id" => attachment_id, "name" => "file.txt"} = descriptor] =
             message.metadata["attachments"]

    assert attachment_id == attachment.id
    refute Map.has_key?(descriptor, "content")
    refute Map.has_key?(descriptor, "raw")
  end

  test "whitespace subject does not assign a conversation title" do
    assert {:ok, %{conversation_id: id}} =
             Conversations.persist_message_history(incoming(), %{
               content: "history",
               metadata: %{"subject" => "  \t "}
             })

    assert is_nil(Conversations.get_conversation!(id).title)
  end

  test "invalid rating-person selectors hide ratings without changing the stored rating" do
    {:ok, conversation} = Conversations.create_conversation(conversation_attrs())

    {:ok, message} =
      Conversations.add_message(conversation, %{role: "user", content: "rated message"})

    {:ok, person_a} = People.create_person(%{full_name: "Rating Person A"})
    {:ok, person_b} = People.create_person(%{full_name: "Rating Person B"})
    {:ok, rating_a} = Conversations.rate_message(message, %{person_id: person_a.id, rating: 5})
    {:ok, rating_b} = Conversations.rate_message(message, %{person_id: person_b.id, rating: 2})

    for selector <- [nil, 0, "not-an-id"] do
      assert [%{ratings: []}] =
               Conversations.list_messages(conversation, rating_person_id: selector)
    end

    assert [%{ratings: [stored_a]}] =
             Conversations.list_messages(conversation, rating_person_id: person_a.id)

    assert stored_a.id == rating_a.id
    assert stored_a.rating == 5

    assert [%{ratings: [stored_b]}] =
             Conversations.list_messages(conversation, rating_person_id: person_b.id)

    assert stored_b.id == rating_b.id
    assert stored_b.rating == 2
  end

  test "invalid rating source reference writes nothing" do
    count = Repo.aggregate(Message, :count)
    assert {:error, :invalid_request} = Conversations.rate_message_by_source(%{}, %{})
    assert Repo.aggregate(Message, :count) == count
  end

  test "user message insertion does not emit assistant-answer telemetry" do
    assert :ok = Buffer.flush()
    config = channel_config_fixture()

    {:ok, conversation} =
      Conversations.create_conversation(
        conversation_attrs(%{channel_type: "mattermost", channel_config_id: config.id})
      )

    dimension_key = "channel_config_id=#{config.id}|channel_type=mattermost|role=assistant"

    matching_answer_points =
      from(p in Zaq.Engine.Telemetry.Point,
        where: p.metric_key == "qa.answer.count" and p.dimension_key == ^dimension_key
      )

    before_count = Repo.aggregate(matching_answer_points, :count)

    assert {:ok, message} =
             Conversations.add_message(conversation, %{role: "user", content: "question"})

    assert message.role == "user"
    assert :ok = Buffer.flush()
    assert Repo.aggregate(matching_answer_points, :count) == before_count
  end
end
