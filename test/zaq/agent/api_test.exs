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

  # Passthrough identity plug (no DB, leaves incoming unchanged)
  defmodule PassthroughIdentityPlug do
    def call(incoming, _opts), do: incoming
  end

  # Passthrough server manager (no-op, returns a fake ref)
  defmodule PassthroughServerManager do
    def ensure_answering_server(server_id),
      do: {:ok, {:via, Registry, {Zaq.Agent.Jido, server_id}}}

    def ensure_server_by_id(_agent, server_id),
      do: {:ok, {:via, Registry, {Zaq.Agent.Jido, server_id}}}
  end

  # Identity plug that records calls and sets person_id = 99
  defmodule SpyIdentityPlug do
    def call(incoming, _opts) do
      send(self(), {:identity_called, incoming})
      %{incoming | person_id: 99}
    end
  end

  # Identity plug that leaves person_id nil (simulates BO user)
  defmodule NilPersonIdentityPlug do
    def call(incoming, _opts), do: %{incoming | person_id: nil}
  end

  # StubServerManager records ensure_answering_server calls
  defmodule SpyServerManager do
    def ensure_answering_server(server_id) do
      send(self(), {:ensure_answering_server, server_id})
      {:ok, {:via, Registry, {Zaq.Agent.Jido, server_id}}}
    end

    def ensure_server_by_id(_agent, server_id) do
      send(self(), {:ensure_server_by_id, server_id})
      {:ok, {:via, Registry, {Zaq.Agent.Jido, server_id}}}
    end
  end

  test "handles run_pipeline action" do
    incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

    event =
      Event.new(incoming, :agent,
        opts: [
          action: :run_pipeline,
          pipeline_module: StubPipeline,
          pipeline_opts: [foo: :bar],
          identity_plug: PassthroughIdentityPlug,
          server_manager: PassthroughServerManager
        ]
      )

    result = Api.handle_event(event, :run_pipeline, nil)

    assert %Outgoing{} = result.response
    assert result.response.body == "ok"
    assert_received {:pipeline_called, ^incoming, opts}
    assert Keyword.get(opts, :foo) == :bar
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
          pipeline_opts: [history: %{"x" => 1}, telemetry_dimensions: %{channel_type: "bo"}],
          identity_plug: PassthroughIdentityPlug,
          server_manager: PassthroughServerManager
        ]
      )

    event =
      %{event | assigns: %{"agent_selection" => %{"agent_id" => "42", "source" => "bo_explicit"}}}

    result = Api.handle_event(event, :run_pipeline, nil)

    assert %Outgoing{} = result.response
    assert result.response.body == "selected"

    assert_received {:executor_called, ^incoming, opts}
    assert Keyword.get(opts, :agent_id) == "42"
    assert Keyword.get(opts, :history) == %{"x" => 1}
    assert Keyword.get(opts, :telemetry_dimensions) == %{channel_type: "bo"}

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
          pipeline_opts: [],
          identity_plug: PassthroughIdentityPlug,
          server_manager: PassthroughServerManager
        ]
      )

    event = %{event | assigns: %{"agent_selection" => %{agent_id: 7}}}

    result = Api.handle_event(event, :run_pipeline, nil)

    assert %Outgoing{} = result.response
    assert result.response.body == "selected"

    assert_received {:executor_called, ^incoming, opts}
    assert Keyword.get(opts, :agent_id) == 7
    assert Keyword.get(opts, :history) == %{}
    assert Keyword.get(opts, :telemetry_dimensions) == %{}
  end

  test "falls back to pipeline when selection is empty or assigns are malformed" do
    incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

    event_empty_selection =
      Event.new(incoming, :agent,
        opts: [
          action: :run_pipeline,
          pipeline_module: StubPipeline,
          pipeline_opts: [foo: :bar],
          identity_plug: PassthroughIdentityPlug,
          server_manager: PassthroughServerManager
        ]
      )

    event_empty_selection =
      %{event_empty_selection | assigns: %{"agent_selection" => %{"agent_id" => ""}}}

    result_1 = Api.handle_event(event_empty_selection, :run_pipeline, nil)

    assert %Outgoing{} = result_1.response
    assert result_1.response.body == "ok"
    assert_received {:pipeline_called, ^incoming, opts1}
    assert Keyword.get(opts1, :foo) == :bar

    event_bad_assigns =
      Event.new(incoming, :agent,
        opts: [
          action: :run_pipeline,
          pipeline_module: StubPipeline,
          pipeline_opts: [],
          identity_plug: PassthroughIdentityPlug,
          server_manager: PassthroughServerManager
        ]
      )

    event_bad_assigns = %{event_bad_assigns | assigns: :not_a_map}
    result_2 = Api.handle_event(event_bad_assigns, :run_pipeline, nil)

    assert %Outgoing{} = result_2.response
    assert result_2.response.body == "ok"
    assert_received {:pipeline_called, ^incoming, _opts2}
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

  # ---------------------------------------------------------------------------
  # New tests: identity resolution + per-person server spawning
  # ---------------------------------------------------------------------------

  describe "identity resolution" do
    test "runs before route decision" do
      incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

      event =
        Event.new(incoming, :agent,
          opts: [
            action: :run_pipeline,
            pipeline_module: StubPipeline,
            pipeline_opts: [],
            identity_plug: SpyIdentityPlug,
            server_manager: SpyServerManager
          ]
        )

      Api.handle_event(event, :run_pipeline, nil)

      # identity plug must be called before the pipeline receives the message
      assert_received {:identity_called, ^incoming}
    end
  end

  describe "pipeline path" do
    test "spawns answering server with answering_{person_id} scope" do
      incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

      event =
        Event.new(incoming, :agent,
          opts: [
            action: :run_pipeline,
            pipeline_module: StubPipeline,
            pipeline_opts: [],
            identity_plug: SpyIdentityPlug,
            server_manager: SpyServerManager
          ]
        )

      Api.handle_event(event, :run_pipeline, nil)

      # person_id = 99 set by SpyIdentityPlug
      assert_received {:ensure_answering_server, "answering_99"}
    end

    test "nil person_id + BO provider (provider: :web) uses metadata.session_id as scope" do
      incoming = %Incoming{
        content: "hi",
        channel_id: "c1",
        provider: :web,
        person_id: nil,
        metadata: %{session_id: "sess_abc"}
      }

      event =
        Event.new(incoming, :agent,
          opts: [
            action: :run_pipeline,
            pipeline_module: StubPipeline,
            pipeline_opts: [],
            identity_plug: NilPersonIdentityPlug,
            server_manager: SpyServerManager
          ]
        )

      Api.handle_event(event, :run_pipeline, nil)

      assert_received {:ensure_answering_server, "answering_sess_abc"}
    end

    test "server ref is passed through pipeline_opts to Pipeline.run" do
      incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

      event =
        Event.new(incoming, :agent,
          opts: [
            action: :run_pipeline,
            pipeline_module: StubPipeline,
            pipeline_opts: [foo: :bar],
            identity_plug: SpyIdentityPlug,
            server_manager: SpyServerManager
          ]
        )

      Api.handle_event(event, :run_pipeline, nil)

      assert_received {:pipeline_called, _incoming, opts}
      assert Keyword.has_key?(opts, :server)
      assert Keyword.get(opts, :server) == {:via, Registry, {Zaq.Agent.Jido, "answering_99"}}
    end
  end

  describe "executor path" do
    test "passes scope to Executor — Executor builds {agent_name}:{scope} server id" do
      incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

      event =
        Event.new(incoming, :agent,
          opts: [
            action: :run_pipeline,
            pipeline_module: StubPipeline,
            executor_module: StubExecutor,
            pipeline_opts: [],
            identity_plug: SpyIdentityPlug,
            server_manager: SpyServerManager
          ]
        )

      event = %{event | assigns: %{"agent_selection" => %{"agent_id" => "42"}}}

      Api.handle_event(event, :run_pipeline, nil)

      assert_received {:executor_called, _incoming, opts}
      assert Keyword.get(opts, :scope) == "99"
      refute Keyword.has_key?(opts, :server_id)
    end

    test "nil person_id + BO provider uses metadata.session_id as scope" do
      incoming = %Incoming{
        content: "hi",
        channel_id: "c1",
        provider: :web,
        person_id: nil,
        metadata: %{session_id: "sess_xyz"}
      }

      event =
        Event.new(incoming, :agent,
          opts: [
            action: :run_pipeline,
            pipeline_module: StubPipeline,
            executor_module: StubExecutor,
            pipeline_opts: [],
            identity_plug: NilPersonIdentityPlug,
            server_manager: SpyServerManager
          ]
        )

      event = %{event | assigns: %{"agent_selection" => %{"agent_id" => "7"}}}

      Api.handle_event(event, :run_pipeline, nil)

      assert_received {:executor_called, _incoming, opts}
      assert Keyword.get(opts, :scope) == "sess_xyz"
    end

    test "scope key is passed through opts to Executor.run" do
      incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

      event =
        Event.new(incoming, :agent,
          opts: [
            action: :run_pipeline,
            pipeline_module: StubPipeline,
            executor_module: StubExecutor,
            pipeline_opts: [history: %{"x" => 1}],
            identity_plug: SpyIdentityPlug,
            server_manager: SpyServerManager
          ]
        )

      event = %{event | assigns: %{"agent_selection" => %{"agent_id" => "5"}}}

      Api.handle_event(event, :run_pipeline, nil)

      assert_received {:executor_called, _incoming, opts}
      assert Keyword.has_key?(opts, :scope)
    end
  end

  describe "same person messaging twice" do
    test "reuses same server (no duplicate spawn)" do
      incoming = %Incoming{content: "first", channel_id: "c1", provider: :web}

      make_event = fn content ->
        Event.new(%{incoming | content: content}, :agent,
          opts: [
            action: :run_pipeline,
            pipeline_module: StubPipeline,
            pipeline_opts: [],
            identity_plug: SpyIdentityPlug,
            server_manager: SpyServerManager
          ]
        )
      end

      Api.handle_event(make_event.("first"), :run_pipeline, nil)
      Api.handle_event(make_event.("second"), :run_pipeline, nil)

      # Both calls use same scope → same server_id
      assert_received {:ensure_answering_server, "answering_99"}
      assert_received {:ensure_answering_server, "answering_99"}
    end
  end
end
