defmodule Zaq.Engine.ApiTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Api
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event

  defmodule StubConversations do
    def persist_from_incoming(incoming, metadata) do
      send(self(), {:persist_called, incoming, metadata})
      :ok
    end
  end

  test "handles persist_from_incoming action" do
    incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}
    metadata = %{answer: "ok"}

    event =
      Event.new(%{incoming: incoming, metadata: metadata}, :engine,
        opts: [action: :persist_from_incoming, conversations_module: StubConversations]
      )

    result = Api.handle_event(event, :persist_from_incoming, nil)

    assert result.response == :ok
    assert_received {:persist_called, ^incoming, ^metadata}
  end

  test "returns invalid request for malformed persist payload" do
    event =
      Event.new(%{incoming: :bad, metadata: %{}}, :engine, opts: [action: :persist_from_incoming])

    result = Api.handle_event(event, :persist_from_incoming, nil)

    assert result.response == {:error, {:invalid_request, %{incoming: :bad, metadata: %{}}}}
  end

  test "delegates invoke to shared helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :engine)
    result = Api.handle_event(event, :invoke, nil)

    assert result.response == "HI"
  end

  test "returns unsupported action" do
    event = Event.new(%{}, :engine)
    result = Api.handle_event(event, :unknown, nil)

    assert result.response == {:error, {:unsupported_action, :unknown}}
  end
end
