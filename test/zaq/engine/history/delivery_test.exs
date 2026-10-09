defmodule Zaq.Engine.History.DeliveryTest do
  use Zaq.DataCase, async: false
  use Oban.Testing, repo: Zaq.Repo
  use ExUnitProperties

  alias Zaq.Accounts.People
  alias Zaq.Engine.{ChannelConfig, Conversations, HistoryDeliveryWorker}
  alias Zaq.Engine.Conversations.{Message, Transcript}
  alias Zaq.Engine.History.Delivery
  alias Zaq.Engine.Messages.Outgoing

  test "unsupported conversation type preserves a confirmed receipt without attempting history capture" do
    config = connector()

    outgoing = %{
      outgoing(config.id, :unknown)
      | metadata: %{user_message_id: unique_id(), assistant_message_id: unique_id()}
    }

    receipt = %{confirmation: :confirmed, message_id: unique_id()}

    assert {:ok, ^receipt} = Delivery.capture({:ok, receipt}, outgoing)
    assert Repo.aggregate(Message, :count) == 0
  end

  property "unsupported conversation types preserve receipt and do not capture history" do
    check all(type <- member_of([nil, :unknown, :broadcast]), max_runs: 12) do
      config = connector()

      outgoing = %{
        outgoing(config.id, type)
        | metadata: %{user_message_id: unique_id(), assistant_message_id: unique_id()}
      }

      receipt = %{confirmation: :confirmed, message_id: unique_id()}

      assert {:ok, ^receipt} = Delivery.capture({:ok, receipt}, outgoing)
      assert Repo.aggregate(Message, :count) == 0
    end
  end

  test "replicated confirmation associates message with every linked recipient using first recipient as channel scope" do
    config = connector("email:imap")
    first = author("First", "first@example.com", config.id)
    later = author("Later", "later@example.com", config.id)
    unrelated = author("Unrelated", "other@example.com", config.id)

    outgoing = %Outgoing{
      body: "confirmed reply",
      channel_id: "old-thread",
      provider: "email:imap",
      metadata: %{},
      routing_context: %{
        channel_config_id: config.id,
        conversation_type: :recipient_addressed,
        source_scope: "smtp:confirmed"
      }
    }

    receipt = %{
      confirmation: :confirmed,
      message_id: unique_id(),
      audience: %{
        platform: "email",
        sender: "system@example.com",
        recipients: ["first@example.com", "later@example.com"]
      }
    }

    assert {:ok, %{history_capture: :stored}} = Delivery.capture({:ok, receipt}, outgoing)
    [message] = Repo.all(Message)
    transcript_ids = message.metadata["history_association"]["transcript_ids"]
    transcripts = Repo.all(Transcript) |> Map.new(&{&1.id, &1})

    for person <- [first, later] do
      transcript =
        Enum.find_value(transcript_ids, fn id ->
          candidate = Map.fetch!(transcripts, id)
          if candidate.owner_person_id == person.id, do: candidate
        end)

      assert transcript
      assert transcript.external_channel_id == "first@example.com"
      assert transcript.owner_person_id == person.id
    end

    refute Enum.any?(transcript_ids, fn id ->
             Map.fetch!(transcripts, id).owner_person_id == unrelated.id
           end)

    assert {:ok, [%{content: "confirmed reply", message_id: id}]} =
             Conversations.list_canonical_messages(
               first,
               Enum.find_value(transcript_ids, fn tid ->
                 if Map.fetch!(transcripts, tid).owner_person_id == first.id, do: tid
               end)
             )

    assert id == message.id
  end

  test "history association exception retains successful transport response and has no side effects" do
    config = connector()

    outgoing = %{
      outgoing(config.id, :room)
      | routing_context: %{
          channel_config_id: config.id,
          conversation_type: :room,
          source_scope: self()
        },
        metadata: %{user_message_id: unique_id(), assistant_message_id: unique_id()}
    }

    receipt = %{confirmation: :confirmed, message_id: unique_id()}

    assert {:ok,
            %{history_capture: :unavailable, history_capture_error: :history_capture_unavailable}} =
             Delivery.capture({:ok, receipt}, outgoing)

    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(Transcript, :count) == 0
    refute_enqueued(worker: HistoryDeliveryWorker)
  end

  defp connector(provider \\ "mattermost") do
    if provider == "email:imap" do
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Delivery SMTP #{unique_id()}",
        provider: "email:smtp",
        kind: "retrieval",
        url: "https://example.invalid",
        token: "token"
      })
      |> Repo.insert!()
    end

    %ChannelConfig{}
    |> ChannelConfig.changeset(%{
      name: "Delivery #{unique_id()}",
      provider: provider,
      kind: "retrieval",
      url: "https://example.invalid",
      token: "token",
      settings:
        if(provider == "email:imap",
          do: %{"imap" => %{"selected_mailboxes" => ["INBOX"]}},
          else: %{}
        )
    })
    |> Repo.insert!()
  end

  defp author(name, address, config_id) do
    {:ok, person} =
      People.find_or_create_from_channel("email:imap", %{
        channel_id: address,
        channel_config_id: config_id,
        display_name: name
      })

    person
  end

  defp outgoing(config_id, type) do
    %Outgoing{
      body: "answer",
      channel_id: "room",
      provider: "mattermost",
      metadata: %{},
      routing_context: %{
        channel_config_id: config_id,
        conversation_type: if(type == :room, do: :room, else: type)
      }
    }
  end

  defp unique_id, do: "delivery-#{System.unique_integer([:positive])}"
end
