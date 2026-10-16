defmodule Zaq.Agent.ProcessingStatusTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Api
  alias Zaq.Event

  test "missing identity or malformed scope cannot inspect processing" do
    for actor <- [nil, %{}, %{person: %{id: 0}}],
        request <- [%{}, %{user_message_ids: ["input"]}] do
      event = Event.new(request, :agent, actor: actor, opts: [confidential: true])

      assert %{response: {:error, :unauthorized}} =
               Api.handle_event(event, :processing_status, nil)
    end
  end

  test "processing inspection requires a confidential internal Person request" do
    for request <- [
          %{user_message_ids: nil},
          %{user_message_ids: [nil]},
          %{user_message_ids: List.duplicate("id", 101)}
        ] do
      event = Event.new(request, :agent, actor: %{person: %{id: 1}}, opts: [confidential: true])

      assert %{response: {:error, :unauthorized}} =
               Api.handle_event(event, :processing_status, nil)
    end

    event = Event.new(%{}, :agent, actor: %{person: %{id: 1}})
    assert %{response: {:error, :unauthorized}} = Api.handle_event(event, :processing_status, nil)
  end
end
