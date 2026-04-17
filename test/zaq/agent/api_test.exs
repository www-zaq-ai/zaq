defmodule Zaq.Agent.ApiTest do
  use ExUnit.Case, async: true

  alias Zaq.Agent.Api
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event

  defmodule StubPipeline do
    def run(%Incoming{} = incoming, opts) do
      send(self(), {:pipeline_called, incoming, opts})

      %Outgoing{body: "ok", channel_id: incoming.channel_id, provider: incoming.provider}
    end
  end

  test "handles run_pipeline action" do
    incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

    event =
      Event.new(incoming, :agent,
        opts: [action: :run_pipeline, pipeline_module: StubPipeline, pipeline_opts: [foo: :bar]]
      )

    result = Api.handle_event(event, :run_pipeline, nil)

    assert %Outgoing{} = result.response
    assert result.response.body == "ok"
    assert_received {:pipeline_called, ^incoming, [foo: :bar]}
  end

  test "returns invalid request for run_pipeline with malformed payload" do
    event = Event.new(%{bad: true}, :agent, opts: [action: :run_pipeline])

    result = Api.handle_event(event, :run_pipeline, nil)

    assert result.response == {:error, {:invalid_request, %{bad: true}}}
  end

  test "delegates invoke to shared internal boundaries helper" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :agent)

    result = Api.handle_event(event, :invoke, nil)

    assert result.response == "HI"
  end

  test "returns unsupported action" do
    event = Event.new(%{module: String, function: :upcase, args: ["hi"]}, :agent)
    result = Api.handle_event(event, :unknown_action, nil)

    assert result.response == {:error, {:unsupported_action, :unknown_action}}
  end
end
