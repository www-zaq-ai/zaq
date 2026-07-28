defmodule Zaq.Engine.Messages.Incoming.RoutingContextTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Messages.Incoming.RoutingContext

  test "normalize/1 converts blank topic_id strings to nil" do
    context =
      RoutingContext.normalize(%{
        channel_config_id: 12,
        retrieval_channel_id: 34,
        topic_id: " \n\t "
      })

    assert context == %RoutingContext{
             channel_config_id: 12,
             retrieval_channel_id: 34,
             topic_id: nil,
             attributes: %{}
           }
  end

  test "normalize/1 normalizes blank topic_id on existing routing context structs" do
    context =
      RoutingContext.normalize(%RoutingContext{
        channel_config_id: "42",
        retrieval_channel_id: "8",
        topic_id: "   ",
        attributes: %{"source" => "mailbox"}
      })

    assert context == %RoutingContext{
             channel_config_id: 42,
             retrieval_channel_id: 8,
             topic_id: nil,
             attributes: %{"source" => "mailbox"}
           }
  end
end
