defmodule Zaq.Engine.History.CommunicationPolicyTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.History.CommunicationPolicy
  alias Zaq.Engine.Messages.Incoming

  test "strategy selection uses communication facts, not the provider" do
    for provider <- ["telegram", "mattermost", "email:imap", "custom"] do
      for {type, kind} <- [one_to_one: :direct, room: :channel, recipient_addressed: :replicated] do
        incoming = message(provider, %{conversation_type: type})
        assert CommunicationPolicy.kind(incoming) == {:ok, kind}
      end
    end
  end

  test "missing and malformed facts never become an inferred history strategy" do
    for type <- [nil, :direct, :shared, :replicated, "room", true] do
      assert {:error, :unsupported_history_kind} =
               CommunicationPolicy.kind(message("telegram", %{conversation_type: type}))
    end
  end

  test "legacy transport strategy hints cannot select a strategy" do
    for kind <- [:direct, :channel, :replicated] do
      assert {:error, :unsupported_history_kind} =
               CommunicationPolicy.kind(message("telegram", %{history_kind: kind}))
    end
  end

  defp message(provider, context) do
    Incoming.new(%{
      content: "hello",
      channel_id: "room",
      provider: provider,
      routing_context: context
    })
  end
end
