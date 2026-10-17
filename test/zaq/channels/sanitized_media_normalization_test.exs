defmodule Zaq.Channels.SanitizedMediaNormalizationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Chat.{Incoming, Media}
  alias Jido.Chat.WhatsApp.Adapter
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.JidoChatBridge.Incoming, as: Normalization

  defmodule MediaTransport do
    def resolve_conn(_opts), do: {:ok, :connection}
    def media_reference(:connection, _descriptor), do: {:ok, "opaque-media-reference"}
  end

  test "sealed adapter media retains room facts, sender membership and timestamp" do
    for {room, type, dm, kind} <- [
          {"123@g.us", :group, false, :room},
          {"15550001@s.whatsapp.net", :dm, true, :one_to_one}
        ],
        caption <- [nil, "photo caption"],
        mentioned? <- [false, true] do
      assert {:ok, source} =
               Adapter.transform_incoming(
                 %{
                   id: "media-1",
                   channel_jid: room,
                   from_jid: "15550002@s.whatsapp.net",
                   timestamp: 1_700_000_000,
                   account_jids: ["15550001@s.whatsapp.net"],
                   mentions: if(mentioned?, do: ["15550001@s.whatsapp.net"], else: []),
                   type: :media,
                   content: %{
                     kind: :image,
                     caption: caption,
                     file_length: 4,
                     direct_path: "/private-media-path",
                     media_key: :binary.copy(<<1>>, 32)
                   }
                 },
                 conn: :connection,
                 transport: MediaTransport
               )

      assert source.raw == %{
               channel_jid: room,
               from_jid: "15550002@s.whatsapp.net",
               timestamp: 1_700_000_000
             }

      refute inspect(source) =~ "private-media-path"
      refute inspect(source) =~ "media_key"
      assert source.chat_type == type
      assert source.channel_meta.is_dm == dm
      assert source.was_mentioned == mentioned?

      for raw <- [%{}, %{source.raw | channel_jid: "other@g.us"}] do
        assert Normalization.normalize(%{source | raw: raw}, :whatsapp, Adapter) == %{}
      end

      internal = JidoChatBridge.to_internal(source, %{provider: :whatsapp, id: 42})
      assert internal.routing_context.conversation_type == kind
      assert internal.routing_context.source_scope == room
      assert internal.routing_context.provider_sent_at == ~U[2023-11-14 22:13:20Z]
      assert [_] = internal.attachments
      refute inspect(internal) =~ "private-media-path"

      if kind == :room do
        assert internal.routing_context.sender_membership == %{
                 identity_platform: "whatsapp",
                 member_id: "15550002@s.whatsapp.net"
               }
      end
    end
  end

  test "Telegram media retains native facts for ordinary provider normalization" do
    for {type, kind} <- [
          {"group", :room},
          {"supergroup", :room},
          {"channel", :room},
          {"private", :one_to_one}
        ] do
      assert {:ok, source} =
               Jido.Chat.Telegram.Adapter.transform_incoming(%{
                 "message" => %{
                   "message_id" => 42,
                   "chat" => %{"id" => -100_123, "type" => type},
                   "from" => %{"id" => 12_345},
                   "date" => 1_700_000_000,
                   "photo" => [%{"file_id" => "telegram-photo", "width" => 10, "height" => 10}]
                 }
               })

      assert [_] = source.media
      assert source.raw["chat"] == %{"id" => -100_123, "type" => type}

      assert Normalization.normalize(source, :telegram, Jido.Chat.Telegram.Adapter) == %{
               conversation_type: kind,
               source_scope: "-100123",
               sender_id: "12345",
               provider_sent_at: ~U[2023-11-14 22:13:20Z]
             }

      assert Normalization.normalize(%{source | raw: %{}}, :telegram, Jido.Chat.Telegram.Adapter) ==
               %{}
    end
  end

  test "sanitized facts require complete explicit adapter evidence" do
    source = sanitized()

    for invalid <- [
          source,
          %{source | media: []},
          %{source | author: nil},
          %{source | external_user_id: nil},
          %{source | chat_type: nil},
          %{source | channel_meta: %{source.channel_meta | external_room_id: nil}},
          %{source | channel_meta: %{source.channel_meta | adapter_name: nil}},
          %{source | channel_meta: %{source.channel_meta | chat_type: :unknown}},
          %{source | channel_meta: %{source.channel_meta | is_dm: true}},
          %{source | raw: %{chat: %{id: "other", type: "group"}}}
        ] do
      assert Normalization.normalize(invalid, :telegram, Jido.Chat.Telegram.Adapter) == %{}
    end

    discord =
      sanitized(%{
        chat_type: :guild,
        channel_meta: %{adapter_name: :discord, chat_type: :guild}
      })

    assert Normalization.normalize(discord, :discord, Jido.Chat.Discord.Adapter) == %{}
  end

  property "contradictory normalized room and sender identifiers never authorize history" do
    check all(other <- string(:alphanumeric, min_length: 1, max_length: 30)) do
      source = sanitized()

      for invalid <- [
            %{source | external_room_id: "other-" <> other},
            %{source | external_user_id: "other-" <> other},
            %{source | channel_meta: %{source.channel_meta | adapter_name: :other}}
          ] do
        assert Normalization.normalize(invalid, :telegram, Jido.Chat.Telegram.Adapter) == %{}
      end
    end
  end

  defp sanitized(overrides \\ %{}) do
    metadata = %{
      adapter_name: :telegram,
      external_room_id: "-100123",
      chat_type: :group,
      is_dm: false
    }

    Incoming.new(
      Map.merge(
        %{
          external_room_id: "-100123",
          external_user_id: "sender",
          chat_type: :group,
          timestamp: ~U[2023-11-14 22:13:20Z],
          raw: %{},
          media: [%Media{kind: :file, metadata: %{file_id: "sealed-reference"}}]
        },
        overrides
      )
      |> Map.put(:channel_meta, Map.merge(metadata, Map.get(overrides, :channel_meta, %{})))
    )
  end
end
