defmodule Zaq.Channels.Retrieval.Mattermost.EventParserTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Retrieval.Mattermost.EventParser

  test "parse/2 extracts posted event data" do
    post = %{
      "id" => "post-1",
      "message" => "@zaq where is the doc?",
      "user_id" => "user-1",
      "channel_id" => "channel-1",
      "root_id" => "",
      "create_at" => 1_710_000_000
    }

    raw_event = %{
      "data" => %{
        "post" => Jason.encode!(post),
        "sender_name" => "alice",
        "channel_type" => "O",
        "channel_name" => "engineering"
      }
    }

    assert {:ok, parsed} = EventParser.parse("posted", raw_event)
    assert parsed.id == "post-1"
    assert parsed.message == "@zaq where is the doc?"
    assert parsed.user_id == "user-1"
    assert parsed.channel_id == "channel-1"
    assert parsed.root_id == ""
    assert parsed.sender_name == "alice"
    assert parsed.channel_type == "O"
    assert parsed.channel_name == "engineering"
    assert parsed.create_at == 1_710_000_000
  end

  test "parse/2 returns decode error for malformed posted payload" do
    raw_event = %{"data" => %{"post" => "{not-json"}}

    assert {:error, _reason} = EventParser.parse("posted", raw_event)
  end

  test "parse/2 marks unknown events" do
    assert {:unknown, "typing"} = EventParser.parse("typing", %{"data" => %{}})
  end
end
