defmodule Zaq.Channels.IncomingNormalizationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.JidoChatBridge.Incoming
  alias Zaq.Channels.JidoChatBridge.Incoming.{Discord, Mattermost, Telegram}
  alias Zaq.TestSupport.OpenAIStub

  defmodule DiscordMetadataAdapter do
    def fetch_metadata(room, opts) do
      send(self(), {:fetch_metadata, room, opts})
      Process.get(:discord_metadata_result)
    end
  end

  test "Mattermost verifies room and provider channel type" do
    meta = %{chat_type: :public, is_dm: false, external_room_id: "room-1"}

    raw = %{
      "channel_type" => "O",
      "post" => %{"channel_id" => "room-1", "create_at" => 1_700_000_000_000}
    }

    assert {:ok, %{conversation_type: :room, source_scope: nil, provider_sent_at: %DateTime{}}} =
             Mattermost.normalize(meta, raw, nil)

    assert {:error, :unverified_communication_facts} =
             Mattermost.normalize(meta, put_in(raw, ["post", "channel_id"], "other"), nil)

    assert {:error, :unverified_communication_facts} =
             Mattermost.normalize(meta, %{raw | "channel_type" => "D"}, nil)
  end

  test "Mattermost rejects malformed normalization inputs" do
    assert {:error, :unverified_communication_facts} = Mattermost.normalize(nil, %{}, nil)
    assert {:error, :unverified_communication_facts} = Mattermost.normalize(%{}, nil, nil)
  end

  test "Mattermost room_members delegates a complete HTTP membership snapshot" do
    room_id = "abcde12345abcde12345abcde1"
    config = %{url: "", token: "test-token"}

    {child_spec, url} =
      OpenAIStub.server(
        fn conn, _body ->
          assert conn.method == "GET"
          assert conn.request_path == "/v1/api/v4/channels/#{room_id}/members"
          assert conn.query_string == "page=0&per_page=200"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
          {200, [%{"user_id" => "user-b"}, %{"user_id" => "user-a"}, %{"user_id" => "user-b"}]}
        end,
        self()
      )

    start_supervised!(child_spec)
    config = %{config | url: url}

    assert {:ok,
            %{complete: true, identity_platform: "mattermost", member_ids: ["user-a", "user-b"]}} =
             Mattermost.room_members(config, room_id)

    assert_receive {:openai_request, "GET", "/v1/api/v4/channels/" <> _, "page=0&per_page=200", _}

    assert {:error, :invalid_channel_id} = Mattermost.room_members(config, "invalid")
    refute_receive {:openai_request, _, _, _, _}
  end

  test "Telegram verifies chat type and emits a chat-local source namespace" do
    meta = %{chat_type: :private, is_dm: true, external_room_id: "-100123"}
    raw = %{"chat" => %{"id" => -100_123, "type" => "private"}, "date" => 1_700_000_000}

    assert {:ok,
            %{
              conversation_type: :one_to_one,
              source_scope: "-100123",
              provider_sent_at: %DateTime{}
            }} = Telegram.normalize(meta, raw, nil)

    assert {:error, :unverified_communication_facts} =
             Telegram.normalize(meta, put_in(raw, ["chat", "type"], "group"), nil)
  end

  test "Telegram rejects malformed metadata and raw inputs" do
    meta = %{chat_type: :private, is_dm: true, external_room_id: "-100123"}
    raw = %{"chat" => %{"id" => -100_123, "type" => "private"}, "date" => 1_700_000_000}

    for malformed_raw <- [nil, [], "invalid"] do
      assert {:error, :unverified_communication_facts} =
               Telegram.normalize(meta, malformed_raw, nil)
    end

    for malformed_meta <- [nil, %{chat_type: :private, external_room_id: "-100123"}] do
      assert {:error, :unverified_communication_facts} =
               Telegram.normalize(malformed_meta, raw, nil)
    end
  end

  test "unsupported providers fail closed before inspecting incoming or adapter" do
    assert Incoming.normalize(:not_an_incoming, "unsupported-provider", :not_an_adapter) == %{}
  end

  test "Discord enrichment requires a matching DM room and map metadata" do
    incoming =
      Jido.Chat.Incoming.new(%{
        external_room_id: "dm-1",
        channel_meta: %{chat_type: :dm, is_dm: true, external_room_id: "dm-1"},
        raw: %{"channel_id" => "dm-1"},
        timestamp: "2026-10-03T10:00:00Z"
      })

    for result <- [
          {:ok, %{id: "other", is_dm: true, metadata: %{"id" => "other", "type" => 1}}},
          {:ok, %{id: "dm-1", is_dm: true, metadata: nil}},
          {:ok, %{id: "dm-1", is_dm: true, metadata: []}}
        ] do
      Process.put(:discord_metadata_result, result)
      assert ^incoming = Discord.enrich(incoming, DiscordMetadataAdapter)
      assert_receive {:fetch_metadata, "dm-1", []}
      assert Incoming.normalize(incoming, :discord, DiscordMetadataAdapter) == %{}
      assert_receive {:fetch_metadata, "dm-1", []}
      refute_receive {:fetch_metadata, _, _}
    end
  end

  test "Discord enrichment accepts verified DM metadata but rejects unsupported facts" do
    incoming =
      Jido.Chat.Incoming.new(%{
        external_room_id: "dm-1",
        channel_meta: %{chat_type: :dm, is_dm: true, external_room_id: "dm-1"},
        raw: %{"channel_id" => "dm-1"},
        timestamp: "2026-10-03T10:00:00Z"
      })

    Process.put(
      :discord_metadata_result,
      {:ok, %{id: "dm-1", is_dm: true, metadata: %{"id" => "dm-1", "type" => 1}}}
    )

    enriched = Discord.enrich(incoming, DiscordMetadataAdapter)

    assert enriched == %{
             incoming
             | raw: Map.put(incoming.raw, "channel", %{"id" => "dm-1", "type" => 1})
           }

    assert_receive {:fetch_metadata, "dm-1", []}

    Process.put(
      :discord_metadata_result,
      {:ok, %{id: "dm-1", is_dm: true, metadata: %{"id" => "dm-1", "type" => 1}}}
    )

    assert Incoming.normalize(incoming, :discord, DiscordMetadataAdapter) == %{
             conversation_type: :one_to_one,
             source_scope: nil,
             provider_sent_at: ~U[2026-10-03 10:00:00Z]
           }

    assert_receive {:fetch_metadata, "dm-1", []}

    Process.put(
      :discord_metadata_result,
      {:ok, %{id: "dm-1", is_dm: true, metadata: %{"id" => "dm-1", "type" => 3}}}
    )

    assert Incoming.normalize(incoming, :discord, DiscordMetadataAdapter) == %{}
    assert_receive {:fetch_metadata, "dm-1", []}

    for {meta, raw} <- [
          {%{chat_type: :unknown, is_dm: false, external_room_id: "dm-1"},
           %{guild_id: "guild", channel_id: "dm-1"}},
          {%{chat_type: :guild, is_dm: false, external_room_id: "dm-1"}, nil},
          {nil, %{guild_id: "guild", channel_id: "dm-1"}}
        ] do
      assert {:error, :unverified_communication_facts} = Discord.normalize(meta, raw, nil)
    end
  end

  test "Discord distinguishes guild, thread and verified direct-message evidence" do
    assert {:ok, %{conversation_type: :room}} =
             Discord.normalize(
               %{chat_type: :guild, is_dm: false, external_room_id: "channel-1"},
               %{guild_id: "guild-1", channel_id: "channel-1"},
               "2026-10-03T10:00:00Z"
             )

    assert {:ok, %{conversation_type: :room}} =
             Discord.normalize(
               %{chat_type: :thread, is_dm: false, external_room_id: "parent-1"},
               %{guild_id: "guild-1", channel_id: "thread-1", parent_id: "parent-1"},
               nil
             )

    assert {:ok, %{conversation_type: :one_to_one}} =
             Discord.normalize(
               %{chat_type: :dm, is_dm: true, external_room_id: "dm-1"},
               %{channel: %{id: "dm-1", type: 1}, channel_id: "dm-1", guild_id: nil},
               nil
             )

    assert {:error, :unverified_communication_facts} =
             Discord.normalize(
               %{chat_type: :dm, is_dm: true, external_room_id: "dm-1"},
               %{channel_id: "dm-1", guild_id: nil, type: 1},
               nil
             )
  end

  property "contradictory transport rooms never normalize to a known conversation" do
    check all(
            room <- string(:alphanumeric, min_length: 1, max_length: 30),
            other <- string(:alphanumeric, min_length: 1, max_length: 30),
            room != other
          ) do
      meta = %{chat_type: :group, is_dm: false, external_room_id: room}
      raw = %{chat: %{id: other, type: "group"}}
      assert {:error, :unverified_communication_facts} = Telegram.normalize(meta, raw, nil)
    end
  end
end
