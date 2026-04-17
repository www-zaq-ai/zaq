defmodule Zaq.Channels.ApiTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.Api
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event

  defmodule StubRouter do
    def deliver(%Outgoing{} = outgoing) do
      send(self(), {:router_deliver, outgoing})
      :ok
    end
  end

  test "handles deliver_outgoing action" do
    outgoing = %Outgoing{body: "ok", channel_id: "c1", provider: :web}

    event =
      Event.new(outgoing, :channels, opts: [action: :deliver_outgoing, router_module: StubRouter])

    result = Api.handle_event(event, :deliver_outgoing, nil)

    assert result.response == :ok
    assert_received {:router_deliver, ^outgoing}
  end

  test "delegates invoke to shared helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :channels)

    result = Api.handle_event(event, :invoke, nil)

    assert result.response == "HI"
  end

  test "returns unsupported action when payload/action mismatch" do
    event = Event.new(%{bad: true}, :channels)

    result = Api.handle_event(event, :deliver_outgoing, nil)

    assert result.response == {:error, {:unsupported_action, :deliver_outgoing}}
  end
end
