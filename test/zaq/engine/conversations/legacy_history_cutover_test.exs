Code.require_file("priv/repo/migrations/20260926000000_restrict_legacy_channel_history.exs")

Code.require_file(
  "priv/repo/migrations/20260926000001_include_unplaced_legacy_provider_messages.exs"
)

defmodule Zaq.Engine.Conversations.LegacyHistoryCutoverTest do
  use Zaq.DataCase, async: false

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Engine.ChannelHistoryAdmin
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.{Message, MessageRating, Transcript, TranscriptMessage}
  alias Zaq.Repo.Migrations.IncludeUnplacedLegacyProviderMessages
  alias Zaq.Repo.Migrations.RestrictLegacyChannelHistory

  test "cutover retains original message UUIDs, ratings and private metadata without granting fresh channel history" do
    {:ok, owner} = People.create_person(%{"full_name" => "Legacy owner"})
    {:ok, stranger} = People.create_person(%{"full_name" => "Other person"})

    {:ok, conversation} =
      Conversations.create_conversation(%{
        channel_type: "mattermost",
        person_id: owner.id,
        channel_user_id: "legacy-channel-#{System.unique_integer([:positive])}",
        external_channel_id: "room-legacy"
      })

    message =
      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation.id,
        role: "assistant",
        content: "historic answer",
        metadata: %{"attachment" => %{"name" => "original.pdf"}},
        trace: [%{"private" => "no-public-history"}]
      })
      |> Repo.insert!()

    rating =
      %MessageRating{}
      |> MessageRating.changeset(%{message_id: message.id, person_id: owner.id, rating: 5})
      |> Repo.insert!()

    admitted =
      %Message{}
      |> Message.changeset(%{
        conversation_id: conversation.id,
        role: "user",
        content: "historic admitted request",
        source_provider: "mattermost",
        source_account_key: "legacy-scope",
        external_message_id: "prior-provider-message"
      })
      |> Repo.insert!()

    for statement <- RestrictLegacyChannelHistory.backfill_statements(),
        do: Repo.query!(statement)

    for statement <- IncludeUnplacedLegacyProviderMessages.backfill_statements(),
        do: Repo.query!(statement)

    for statement <- IncludeUnplacedLegacyProviderMessages.backfill_statements(),
        do: Repo.query!(statement)

    for statement <- RestrictLegacyChannelHistory.backfill_statements(),
        do: Repo.query!(statement)

    transcript = Repo.get_by!(Transcript, conversation_id: conversation.id)
    assert transcript.strategy == "legacy"
    assert transcript.permission_resource_type == "legacy_conversation"
    assert transcript.next_position == 2

    placements = Repo.all(from p in TranscriptMessage, where: p.transcript_id == ^transcript.id)

    assert Enum.sort(Enum.map(placements, & &1.message_id)) ==
             Enum.sort([message.id, admitted.id])

    assert Enum.sort(Enum.map(placements, & &1.position)) == [1, 2]
    assert Enum.all?(placements, &(&1.provenance == "legacy_restricted"))

    assert Repo.get!(MessageRating, rating.id).message_id == message.id
    assert Repo.get!(Message, message.id).trace == [%{"private" => "no-public-history"}]

    assert Repo.get!(Message, message.id).metadata == %{
             "attachment" => %{"name" => "original.pdf"}
           }

    assert Conversations.get_person_conversation(conversation.id, owner.id)
    refute Conversations.get_person_conversation(conversation.id, stranger.id)
    assert {:error, :unauthorized} = Conversations.list_canonical_messages(owner, transcript.id)

    assert {:error, :unauthorized} =
             Conversations.list_canonical_messages(stranger, transcript.id)

    assert {:ok, %{transcript: %{strategy: "legacy"}, messages: messages}} =
             ChannelHistoryAdmin.dispatch(%{op: :detail, id: transcript.id})

    assert Enum.sort(Enum.map(messages, & &1.message_id)) == Enum.sort([message.id, admitted.id])

    assert {:error, :not_found} =
             ChannelHistoryAdmin.dispatch(%{op: :grant, id: transcript.id, person_id: owner.id})
  end
end
