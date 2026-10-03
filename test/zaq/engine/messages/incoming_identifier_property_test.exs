defmodule Zaq.Engine.Messages.IncomingIdentifierPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.Messages.Incoming

  property "numeric and string coordinates have identical canonical identities across providers" do
    check all(
            room <- integer(),
            topic <- integer(),
            provider <- member_of([:mattermost, :telegram, :discord])
          ) do
      attrs = %{
        content: "message",
        channel_id: room,
        thread_id: topic,
        message_id: topic,
        provider: provider
      }

      numeric = Incoming.new(attrs)

      text =
        Incoming.new(%{
          attrs
          | channel_id: to_string(room),
            thread_id: to_string(topic),
            message_id: to_string(topic)
        })

      assert numeric == text
      assert numeric.channel_id == to_string(room)
      assert numeric.thread_id == to_string(topic)
      assert numeric.message_id == to_string(topic)
    end
  end
end
