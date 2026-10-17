defmodule Zaq.Engine.Messages.QuotedReplyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Engine.Messages.Incoming

  test "bridge preserves inline WhatsApp quote without creating a thread" do
    incoming = %Jido.Chat.Incoming{
      text: "@bot Explain this",
      external_room_id: "group@g.us",
      external_message_id: "new",
      external_reply_to_id: "original",
      reply_context: %Jido.Chat.ReplyContext{
        external_message_id: "original",
        text: "The launch is Friday",
        author: %Jido.Chat.Author{user_id: "alice", user_name: "Alice"}
      }
    }

    message = JidoChatBridge.to_internal(incoming, %{provider: :whatsapp, id: 42})
    assert message.content == "@bot Explain this"
    assert message.thread_id == nil
    assert message.external_reply_to_id == "original"

    assert message.reply_context == %{
             "external_message_id" => "original",
             "text" => "The launch is Friday",
             "author_id" => "alice",
             "author_name" => "Alice",
             "provider" => "whatsapp",
             "channel_config_id" => 42,
             "channel_id" => "group@g.us",
             "source_scope" => nil
           }
  end

  test "reference-only and malformed quotes remain safe" do
    assert %{reply_context: nil, external_reply_to_id: nil} = incoming(%{})

    for context <- [nil, [], 42, "invalid", %{text: %{invalid: true}, author: false}] do
      message = incoming(%{reply_context: context, external_reply_to_id: 12})
      assert message.external_reply_to_id == "12"
      assert message.reply_context["external_message_id"] == "12"
      assert message.reply_context["text"] == nil
      assert Jason.encode!(message.reply_context)
    end
  end

  test "conflicting room, connector, provider, source or reference cannot supply quoted text" do
    for mismatch <- [
          %{channel_id: "other"},
          %{channel_config_id: 99},
          %{provider: "telegram"},
          %{source_scope: "other"},
          %{external_message_id: "other"}
        ] do
      message =
        incoming(%{
          external_reply_to_id: "original",
          reply_context: Map.merge(%{text: "private original"}, mismatch)
        })

      assert message.reply_context == nil
      assert message.external_reply_to_id == "original"
    end
  end

  property "quote normalization is JSON safe, idempotent and does not change routing identity" do
    check all(value <- term()) do
      message = incoming(%{reply_context: value, external_reply_to_id: value})
      assert Jason.encode!(message.reply_context)
      assert Incoming.new(Map.from_struct(message)) == message
      assert message.channel_id == "room"
      assert message.thread_id == "thread"
      assert message.person == nil
    end
  end

  test "invalid UTF-8, oversized identifiers and nested media are not propagated" do
    for id <- [<<255>>, String.duplicate("x", 1_025)] do
      message =
        incoming(%{
          external_reply_to_id: id,
          reply_context: %{external_message_id: id, text: <<255>>}
        })

      assert message.external_reply_to_id == nil
      assert message.reply_context == nil
    end

    message =
      incoming(%{external_reply_to_id: "media", reply_context: %{media: [%{url: "private"}]}})

    assert message.reply_context["text"] == nil
    refute Map.has_key?(message.reply_context, "media")
  end

  defp incoming(attrs) do
    Incoming.new(
      Map.merge(
        %{
          content: "Explain this",
          channel_id: "room",
          thread_id: "thread",
          provider: :whatsapp,
          channel_config_id: 42
        },
        attrs
      )
    )
  end
end
