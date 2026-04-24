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

  defmodule StubExecutor do
    def run(%Incoming{} = incoming, opts) do
      send(self(), {:executor_called, incoming, opts})
      %Outgoing{body: "selected", channel_id: incoming.channel_id, provider: incoming.provider}
    end
  end

  defmodule StubMCP do
    def test_list_tools(endpoint_id, opts) do
      send(self(), {:mcp_test_called, endpoint_id, opts})
      {:ok, %{status: :ok, endpoint_id: endpoint_id}}
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

  test "delegates to executor when event has explicit agent selection" do
    incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

    event =
      Event.new(incoming, :agent,
        opts: [
          action: :run_pipeline,
          pipeline_module: StubPipeline,
          executor_module: StubExecutor,
          pipeline_opts: [history: %{"x" => 1}, telemetry_dimensions: %{channel_type: "bo"}]
        ]
      )

    event =
      %{event | assigns: %{"agent_selection" => %{"agent_id" => "42", "source" => "bo_explicit"}}}

    result = Api.handle_event(event, :run_pipeline, nil)

    assert %Outgoing{} = result.response
    assert result.response.body == "selected"

    assert_received {:executor_called, ^incoming,
                     [
                       agent_id: "42",
                       history: %{"x" => 1},
                       telemetry_dimensions: %{channel_type: "bo"}
                     ]}

    refute_received {:pipeline_called, _, _}
  end

  test "delegates to executor when agent selection map uses atom key" do
    incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

    event =
      Event.new(incoming, :agent,
        opts: [
          action: :run_pipeline,
          pipeline_module: StubPipeline,
          executor_module: StubExecutor,
          pipeline_opts: []
        ]
      )

    event = %{event | assigns: %{"agent_selection" => %{agent_id: 7}}}

    result = Api.handle_event(event, :run_pipeline, nil)

    assert %Outgoing{} = result.response
    assert result.response.body == "selected"

    assert_received {:executor_called, ^incoming,
                     [agent_id: 7, history: %{}, telemetry_dimensions: %{}]}
  end

  test "falls back to pipeline when selection is empty or assigns are malformed" do
    incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

    event_empty_selection =
      Event.new(incoming, :agent,
        opts: [action: :run_pipeline, pipeline_module: StubPipeline, pipeline_opts: [foo: :bar]]
      )

    event_empty_selection =
      %{event_empty_selection | assigns: %{"agent_selection" => %{"agent_id" => ""}}}

    result_1 = Api.handle_event(event_empty_selection, :run_pipeline, nil)

    assert %Outgoing{} = result_1.response
    assert result_1.response.body == "ok"
    assert_received {:pipeline_called, ^incoming, [foo: :bar]}

    event_bad_assigns =
      Event.new(incoming, :agent,
        opts: [action: :run_pipeline, pipeline_module: StubPipeline, pipeline_opts: []]
      )

    event_bad_assigns = %{event_bad_assigns | assigns: :not_a_map}
    result_2 = Api.handle_event(event_bad_assigns, :run_pipeline, nil)

    assert %Outgoing{} = result_2.response
    assert result_2.response.body == "ok"
    assert_received {:pipeline_called, ^incoming, []}
  end

  test "run_pipeline falls back to pipeline when agent_selection has unsupported shape" do
    incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

    event =
      Event.new(incoming, :agent,
        opts: [action: :run_pipeline, pipeline_module: StubPipeline, pipeline_opts: [foo: :bar]]
      )

    event = %{event | assigns: %{"agent_selection" => %{source: "bo"}}}

    result = Api.handle_event(event, :run_pipeline, nil)

    assert %Outgoing{} = result.response
    assert result.response.body == "ok"
    assert_received {:pipeline_called, ^incoming, [foo: :bar]}
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

  test "delegates mcp_test_list_tools to MCP module" do
    event =
      Event.new(%{endpoint_id: 42}, :agent,
        opts: [action: :mcp_test_list_tools, mcp_module: StubMCP, mcp_test_opts: [timeout: 1234]]
      )

    result = Api.handle_event(event, :mcp_test_list_tools, nil)

    assert result.response == {:ok, %{status: :ok, endpoint_id: 42}}
    assert_received {:mcp_test_called, 42, [timeout: 1234]}
  end

  test "mcp_test_list_tools coerces invalid mcp_test_opts to empty list" do
    event =
      Event.new(%{endpoint_id: 42}, :agent,
        opts: [action: :mcp_test_list_tools, mcp_module: StubMCP, mcp_test_opts: :invalid]
      )

    result = Api.handle_event(event, :mcp_test_list_tools, nil)

    assert result.response == {:ok, %{status: :ok, endpoint_id: 42}}
    assert_received {:mcp_test_called, 42, []}
  end

  test "returns invalid request for mcp_test_list_tools without endpoint id" do
    event = Event.new(%{foo: "bar"}, :agent, opts: [action: :mcp_test_list_tools])

    result = Api.handle_event(event, :mcp_test_list_tools, nil)

    assert result.response == {:error, {:invalid_request, %{foo: "bar"}}}
  end
end
