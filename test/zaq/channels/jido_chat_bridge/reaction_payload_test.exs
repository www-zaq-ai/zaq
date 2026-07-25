defmodule Zaq.Channels.JidoChatBridge.ReactionPayloadTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.EventEnvelope
  alias Jido.Chat.ReactionEvent
  alias Jido.Chat.Thread
  alias Zaq.Channels.JidoChatBridge.ReactionPayload

  defmodule StubAdapter do
    def transform_incoming(_payload), do: {:error, :unsupported}
  end

  # Mirrors Jido.Chat.Discord.GatewayWorker.reaction_envelope/2.
  defp discord_envelope(overrides \\ %{}) do
    payload =
      Map.merge(
        %{
          adapter_name: :discord,
          thread_id: "discord:chan-1",
          message_id: "msg-1",
          emoji: "thumbsup",
          added: true,
          user: %{user_id: "user-1"},
          raw: %{"user_id" => "user-1"},
          metadata: %{channel_id: "chan-1"}
        },
        overrides
      )

    EventEnvelope.new(%{
      adapter_name: :discord,
      event_type: :reaction,
      thread_id: "discord:chan-1",
      channel_id: "chan-1",
      message_id: "msg-1",
      payload: payload,
      raw: %{},
      metadata: %{}
    })
  end

  describe "event_type/1" do
    test "classifies a reaction envelope without raising on the struct" do
      assert :reaction = ReactionPayload.event_type(discord_envelope())
    end

    test "classifies a message envelope" do
      envelope =
        EventEnvelope.new(%{adapter_name: :discord, event_type: :message, payload: %{}})

      assert :message = ReactionPayload.event_type(envelope)
    end

    test "classifies plain maps with atom or string keys" do
      assert :reaction = ReactionPayload.event_type(%{event_type: :reaction})
      assert :reaction = ReactionPayload.event_type(%{"event_type" => "reaction"})
      assert :message = ReactionPayload.event_type(%{event_type: :message})
    end

    test "treats raw provider payloads and non-maps as messages" do
      assert :message = ReactionPayload.event_type(%{"post" => %{"id" => "1"}})
      assert :message = ReactionPayload.event_type(%{})
      assert :message = ReactionPayload.event_type(nil)

      thread =
        Thread.new(%{id: "t-1", adapter_name: :discord, adapter: nil, external_room_id: "chan-1"})

      assert :message = ReactionPayload.event_type(thread)
    end
  end

  describe "to_reaction_event/3" do
    test "normalizes a discord gateway envelope into a reaction event" do
      assert {:ok, %ReactionEvent{} = reaction} =
               ReactionPayload.to_reaction_event(discord_envelope(), :discord, StubAdapter)

      assert reaction.emoji == "thumbsup"
      assert reaction.added
      assert reaction.adapter_name == :discord
      assert reaction.adapter == StubAdapter
      assert reaction.message_id == "msg-1"
      assert reaction.channel_id == "chan-1"
      assert reaction.user.user_id == "user-1"
    end

    test "builds a postable thread handle so follow-ups can be sent" do
      assert {:ok, %ReactionEvent{thread: %Thread{} = thread}} =
               ReactionPayload.to_reaction_event(discord_envelope(), :discord, StubAdapter)

      assert thread.id == "discord:chan-1"
      assert thread.adapter_name == :discord
      assert thread.adapter == StubAdapter
      assert thread.external_room_id == "chan-1"
      assert thread.metadata == %{}
    end

    test "extracts the emoji name from a map-shaped emoji" do
      envelope = discord_envelope(%{emoji: %{name: "thumbsup", id: nil}})

      assert {:ok, %ReactionEvent{emoji: "thumbsup"}} =
               ReactionPayload.to_reaction_event(envelope, :discord, StubAdapter)

      envelope = discord_envelope(%{emoji: %{"name" => "thumbsdown"}})

      assert {:ok, %ReactionEvent{emoji: "thumbsdown"}} =
               ReactionPayload.to_reaction_event(envelope, :discord, StubAdapter)
    end

    test "normalizes the added flag, defaulting to true when absent" do
      assert {:ok, %ReactionEvent{added: false}} =
               ReactionPayload.to_reaction_event(
                 discord_envelope(%{added: false}),
                 :discord,
                 StubAdapter
               )

      assert {:ok, %ReactionEvent{added: true}} =
               ReactionPayload.to_reaction_event(
                 discord_envelope(%{added: "true"}),
                 :discord,
                 StubAdapter
               )

      assert {:ok, %ReactionEvent{added: true}} =
               ReactionPayload.to_reaction_event(
                 %{event_type: :reaction, emoji: "thumbsup", thread_id: "t-1"},
                 :discord,
                 StubAdapter
               )
    end

    test "stringifies numeric ids from providers that send integers" do
      envelope = discord_envelope(%{message_id: 12_345, user: %{user_id: 678}})

      assert {:ok, %ReactionEvent{message_id: "12345", user: user}} =
               ReactionPayload.to_reaction_event(envelope, :discord, StubAdapter)

      assert user.user_id == "678"
    end

    test "normalizes plain atom-keyed and string-keyed payloads" do
      atom_keyed = %{
        event_type: :reaction,
        emoji: "thumbsup",
        added: true,
        thread_id: "telegram:99",
        channel_id: "99",
        message_id: "5",
        user: %{user_id: "42"}
      }

      assert {:ok, %ReactionEvent{emoji: "thumbsup", message_id: "5"}} =
               ReactionPayload.to_reaction_event(atom_keyed, :telegram, StubAdapter)

      string_keyed = %{
        "event_type" => "reaction",
        "emoji" => "thumbsup",
        "added" => "true",
        "thread_id" => "telegram:99",
        "channel_id" => "99",
        "message_id" => "5"
      }

      assert {:ok, %ReactionEvent{emoji: "thumbsup", added: true}} =
               ReactionPayload.to_reaction_event(string_keyed, :telegram, StubAdapter)
    end

    test "ignores payloads with no usable emoji instead of raising" do
      assert :ignored =
               ReactionPayload.to_reaction_event(
                 discord_envelope(%{emoji: nil}),
                 :discord,
                 StubAdapter
               )

      assert :ignored =
               ReactionPayload.to_reaction_event(
                 discord_envelope(%{emoji: %{"id" => "custom-1"}}),
                 :discord,
                 StubAdapter
               )

      assert :ignored = ReactionPayload.to_reaction_event(%{}, :discord, StubAdapter)
      assert :ignored = ReactionPayload.to_reaction_event(nil, :discord, StubAdapter)
    end

    test "still normalizes when no thread handle can be built" do
      assert {:ok, %ReactionEvent{emoji: "thumbsup", thread: nil}} =
               ReactionPayload.to_reaction_event(
                 %{emoji: "thumbsup", message_id: "msg-1"},
                 :discord,
                 StubAdapter
               )
    end
  end
end
