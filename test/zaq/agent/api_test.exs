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

  defmodule StubRuntimeSync do
    def configured_agent_created(attrs) do
      send(self(), {:configured_agent_created_called, attrs})
      {:ok, %{agent: %{id: 1, name: attrs["name"] || attrs[:name]}}}
    end

    def configured_agent_updated(id, attrs) do
      send(self(), {:configured_agent_updated_called, id, attrs})
      {:ok, %{agent: %{id: id, name: attrs["name"] || attrs[:name]}}}
    end

    def configured_agent_deleted(id) do
      send(self(), {:configured_agent_deleted_called, id})
      {:ok, %{agent: %{id: id}}}
    end

    def mcp_endpoint_updated(request) do
      send(self(), {:mcp_endpoint_updated_called, request})
      {:ok, %{endpoint: %{id: 42, name: "MCP"}}}
    end
  end

  # Passthrough identity plug (no DB, leaves incoming unchanged)
  defmodule PassthroughIdentityPlug do
    def call(incoming, _opts), do: incoming
  end

  # Passthrough server manager (no-op, returns a fake ref)
  defmodule PassthroughServerManager do
    def ensure_server(server_id),
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

  # StubServerManager records ensure_server calls
  defmodule SpyServerManager do
    def ensure_server(server_id) do
      send(self(), {:ensure_server, server_id})
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
    assert_received {:pipeline_called, ^incoming, opts}
    assert Keyword.get(opts, :foo) == :bar
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

  test "delegates configured_agent_created to runtime sync module" do
    event =
      Event.new(%{attrs: %{"name" => "Agent"}}, :agent,
        opts: [action: :configured_agent_created, runtime_sync_module: StubRuntimeSync]
      )

    result = Api.handle_event(event, :configured_agent_created, nil)

    assert result.response == {:ok, %{agent: %{id: 1, name: "Agent"}}}
    assert_received {:configured_agent_created_called, %{"name" => "Agent"}}
  end

  test "configured_agent_created accepts string attrs key and rejects invalid payload" do
    ok_event =
      Event.new(%{"attrs" => %{"name" => "Agent String"}}, :agent,
        opts: [action: :configured_agent_created, runtime_sync_module: StubRuntimeSync]
      )

    assert Api.handle_event(ok_event, :configured_agent_created, nil).response ==
             {:ok, %{agent: %{id: 1, name: "Agent String"}}}

    bad_event = Event.new(%{foo: "bar"}, :agent, opts: [action: :configured_agent_created])

    assert Api.handle_event(bad_event, :configured_agent_created, nil).response ==
             {:error, {:invalid_request, %{foo: "bar"}}}
  end

  test "configured_agent_updated validates request shape" do
    event = Event.new(%{id: "1", attrs: %{}}, :agent, opts: [action: :configured_agent_updated])

    result = Api.handle_event(event, :configured_agent_updated, nil)

    assert result.response == {:error, {:invalid_request, %{id: "1", attrs: %{}}}}
  end

  test "delegates configured_agent_updated, configured_agent_deleted, and mcp_endpoint_updated" do
    updated_event =
      Event.new(%{id: 9, attrs: %{"name" => "Updated"}}, :agent,
        opts: [action: :configured_agent_updated, runtime_sync_module: StubRuntimeSync]
      )

    deleted_event =
      Event.new(%{id: 9}, :agent,
        opts: [action: :configured_agent_deleted, runtime_sync_module: StubRuntimeSync]
      )

    mcp_event =
      Event.new(%{action: :create, attrs: %{name: "X"}}, :agent,
        opts: [action: :mcp_endpoint_updated, runtime_sync_module: StubRuntimeSync]
      )

    assert Api.handle_event(updated_event, :configured_agent_updated, nil).response ==
             {:ok, %{agent: %{id: 9, name: "Updated"}}}

    assert Api.handle_event(deleted_event, :configured_agent_deleted, nil).response ==
             {:ok, %{agent: %{id: 9}}}

    assert Api.handle_event(mcp_event, :mcp_endpoint_updated, nil).response ==
             {:ok, %{endpoint: %{id: 42, name: "MCP"}}}

    assert_received {:configured_agent_updated_called, 9, %{"name" => "Updated"}}
    assert_received {:configured_agent_deleted_called, 9}
    assert_received {:mcp_endpoint_updated_called, %{action: :create, attrs: %{name: "X"}}}
  end

  test "configured_agent_updated and configured_agent_deleted support string keys" do
    updated_event =
      Event.new(%{"id" => 10, "attrs" => %{"name" => "String Updated"}}, :agent,
        opts: [action: :configured_agent_updated, runtime_sync_module: StubRuntimeSync]
      )

    deleted_event =
      Event.new(%{"id" => 10}, :agent,
        opts: [action: :configured_agent_deleted, runtime_sync_module: StubRuntimeSync]
      )

    assert Api.handle_event(updated_event, :configured_agent_updated, nil).response ==
             {:ok, %{agent: %{id: 10, name: "String Updated"}}}

    assert Api.handle_event(deleted_event, :configured_agent_deleted, nil).response ==
             {:ok, %{agent: %{id: 10}}}
  end

  test "configured_agent_deleted and mcp_endpoint_updated reject invalid payloads" do
    bad_delete = Event.new(%{id: "10"}, :agent, opts: [action: :configured_agent_deleted])

    assert Api.handle_event(bad_delete, :configured_agent_deleted, nil).response ==
             {:error, {:invalid_request, %{id: "10"}}}

    bad_mcp = Event.new(:bad, :agent, opts: [action: :mcp_endpoint_updated])

    assert Api.handle_event(bad_mcp, :mcp_endpoint_updated, nil).response ==
             {:error, {:invalid_request, :bad}}
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
    test "passes scope derived from person_id into pipeline_opts" do
      incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

      event =
        Event.new(incoming, :agent,
          opts: [
            action: :run_pipeline,
            pipeline_module: StubPipeline,
            pipeline_opts: [],
            identity_plug: SpyIdentityPlug
          ]
        )

      Api.handle_event(event, :run_pipeline, nil)

      # person_id = 99 set by SpyIdentityPlug
      assert_received {:pipeline_called, _incoming, opts}
      assert Keyword.get(opts, :scope) == "99"
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
            identity_plug: NilPersonIdentityPlug
          ]
        )

      Api.handle_event(event, :run_pipeline, nil)

      assert_received {:pipeline_called, _incoming, opts}
      assert Keyword.get(opts, :scope) == "sess_abc"
    end

    test "scope is passed through pipeline_opts to Pipeline.run" do
      incoming = %Incoming{content: "hi", channel_id: "c1", provider: :web}

      event =
        Event.new(incoming, :agent,
          opts: [
            action: :run_pipeline,
            pipeline_module: StubPipeline,
            pipeline_opts: [foo: :bar],
            identity_plug: SpyIdentityPlug
          ]
        )

      Api.handle_event(event, :run_pipeline, nil)

      assert_received {:pipeline_called, _incoming, opts}
      assert Keyword.has_key?(opts, :scope)
      assert Keyword.get(opts, :scope) == "99"
      assert Keyword.get(opts, :foo) == :bar
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
    test "passes same scope to pipeline on both calls" do
      incoming = %Incoming{content: "first", channel_id: "c1", provider: :web}

      make_event = fn content ->
        Event.new(%{incoming | content: content}, :agent,
          opts: [
            action: :run_pipeline,
            pipeline_module: StubPipeline,
            pipeline_opts: [],
            identity_plug: SpyIdentityPlug
          ]
        )
      end

      Api.handle_event(make_event.("first"), :run_pipeline, nil)
      Api.handle_event(make_event.("second"), :run_pipeline, nil)

      # Both calls use same scope
      assert_received {:pipeline_called, _, opts1}
      assert_received {:pipeline_called, _, opts2}
      assert Keyword.get(opts1, :scope) == "99"
      assert Keyword.get(opts2, :scope) == "99"
    end
  end
end
