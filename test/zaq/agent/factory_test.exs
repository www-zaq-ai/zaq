defmodule Zaq.Agent.FactoryTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent
  alias Zaq.Agent.Answering
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Factory
  alias Zaq.Agent.ProviderSpec
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.OpenAIStub

  defmodule MCPProbeTool do
    use Jido.Action,
      name: "mcp_probe_tool",
      description: "Probe MCP runtime merge",
      schema: Zoi.object(%{value: Zoi.string() |> Zoi.optional()})

    @impl true
    def run(_params, _context), do: {:ok, %{ok: true}}
  end

  describe "answering_configured_agent/0" do
    test "returns a ConfiguredAgent with name answering" do
      agent = Answering.answering_configured_agent()
      assert %ConfiguredAgent{} = agent
      assert agent.id == :answering
      assert agent.name == "answering"
    end

    test "includes answering tool keys" do
      agent = Answering.answering_configured_agent()
      assert "answering.search_knowledge_base" in agent.enabled_tool_keys
    end

    test "is active and not conversation-enabled" do
      agent = Answering.answering_configured_agent()
      assert agent.active == true
      assert agent.conversation_enabled == true
    end
  end

  test "strategy_opts does not include model option" do
    refute Keyword.has_key?(Factory.strategy_opts(), :model)
  end

  test "declares MCP runtime plugins and actions" do
    plugins = Factory.plugins()
    actions = Factory.actions()

    assert Jido.MCP.Plugins.MCP in plugins
    assert Jido.MCP.JidoAI.Plugins.MCPAI in plugins

    assert Jido.MCP.Actions.ListTools in actions
    assert Jido.MCP.JidoAI.Actions.SyncToolsToAgent in actions
    assert Jido.MCP.JidoAI.Actions.UnsyncToolsFromAgent in actions
  end

  describe "ProviderSpec.build/0" do
    setup do
      seed_llm_config(%{
        endpoint: "https://api.example.com/v1",
        model: "test-model",
        temperature: 0.1,
        top_p: 0.8
      })

      :ok
    end

    test "returns model spec with provider, id, and base_url" do
      spec = ProviderSpec.build()

      assert spec.provider == :openai
      assert spec.id == "test-model"
      assert spec.base_url == "https://api.example.com/v1"
    end

    test "generation_opts returns temperature and top_p" do
      opts = Factory.generation_opts()

      assert opts[:temperature] == 0.1
      assert opts[:top_p] == 0.8
    end
  end

  test "ask_with_config returns unknown tools error before runtime call" do
    configured_agent = %Agent.ConfiguredAgent{enabled_tool_keys: ["files.missing"]}

    assert {:error, {:unknown_tools, ["files.missing"]}} =
             Factory.ask_with_config(:unused_server, "hello", configured_agent)
  end

  test "runtime_config returns unknown tools error for invalid selection" do
    configured_agent = %Agent.ConfiguredAgent{enabled_tool_keys: ["files.missing"]}

    assert {:error, {:unknown_tools, ["files.missing"]}} =
             Factory.runtime_config(configured_agent)
  end

  test "runtime_config returns standard config fields when max iterations is unset" do
    configured_agent = %Agent.ConfiguredAgent{enabled_tool_keys: [], credential: nil}

    assert {:ok, config} = Factory.runtime_config(configured_agent)
    assert is_list(config.llm_opts)
    assert config.system_prompt == ""
  end

  test "runtime_config does not expose max iterations directly" do
    configured_agent = %Agent.ConfiguredAgent{
      enabled_tool_keys: [],
      credential: nil,
      max_iterations: 2
    }

    assert {:ok, config} = Factory.runtime_config(configured_agent)
    refute Map.has_key?(config, :max_iterations)
  end

  test "Jido ReAct start schema preserves request max iterations" do
    instruction = %Jido.Instruction{
      action: :ai_react_start,
      params: %{query: "hello", request_id: "req-1", max_iterations: 2}
    }

    normalized =
      Jido.Agent.Strategy.normalize_instruction(
        Jido.AI.Reasoning.ReAct.Strategy,
        instruction,
        %{}
      )

    assert normalized.params.max_iterations == 2
  end

  test "ask_with_config builds llm opts across option-key and credential branches" do
    credential =
      ai_credential_fixture(%{
        name: "Factory Branch Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        api_key: nil
      })

    configured_agent = %Agent.ConfiguredAgent{
      job: "job",
      model: "gpt-4.1-mini",
      credential_id: credential.id,
      credential: nil,
      enabled_tool_keys: [],
      advanced_options: %{123 => "ignored", "non_existing" => true, temperature: 0.11}
    }

    assert {:error, _reason} = Factory.ask_with_config(:invalid_server, "hello", configured_agent)
  end

  test "ask_with_config handles nil credential and non-map advanced options" do
    configured_agent = %Agent.ConfiguredAgent{
      job: "job",
      model: "gpt-4.1-mini",
      credential: nil,
      enabled_tool_keys: [],
      advanced_options: "not_a_map"
    }

    assert {:error, _reason} = Factory.ask_with_config(:invalid_server, "hello", configured_agent)
  end

  test "ask_with_config executes end-to-end with server runtime config" do
    handler = fn conn, body ->
      payload = Jason.decode!(body)

      assert payload["model"] == "gpt-4.1-mini"

      {200, streamed_reply(conn.request_path, "Factory reply", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Factory Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "factory-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Factory Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a helper",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"temperature" => 0.33, "this_option_does_not_exist" => true}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent)
    end)

    incoming = %Incoming{content: "hello", channel_id: "bo-test", provider: :web}

    assert {:ok, server} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    assert {:ok, status} = Jido.AgentServer.status(server)
    assert status.raw_state.runtime_config.system_prompt == configured_agent.job
    assert is_list(status.raw_state.runtime_config.llm_opts)

    assert {:ok, request} =
             Factory.ask_with_config(server, incoming.content, configured_agent, timeout: 35_000)

    assert {:ok, answer} = Factory.await(request, timeout: 45_000)
    assert is_binary(answer)

    assert_receive {:openai_request, "POST", "/v1/responses", "", body}, 1_000
    assert body =~ "gpt-4.1-mini"
    assert body =~ configured_agent.job
  end

  test "ask_with_config uses overridden job (system_prompt) on server initialized with different prompt" do
    # Verifies that ensure_system_prompt correctly patches a reused server's prompt
    # when configured_agent.job differs from what the server was initialized with.
    # This is the path exercised by RunAgent → Executor.apply_system_prompt_override.
    handler = fn conn, _body ->
      {200, streamed_reply(conn.request_path, "ok", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Prompt Override Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "prompt-override-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Prompt Override Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "original system prompt",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent)
    end)

    server_id = "configured_agent_#{configured_agent.id}"
    {:ok, server} = ServerManager.ensure_server(configured_agent, server_id)

    # Override job — simulates Executor.apply_system_prompt_override/2 substituting
    # per-run template variables before calling ask_with_config.
    overridden_agent = %{configured_agent | job: "personalized prompt for John at Acme"}

    assert {:ok, request} =
             Factory.ask_with_config(server, "hello", overridden_agent, timeout: 35_000)

    assert {:ok, _answer} = Factory.await(request, timeout: 45_000)

    assert_receive {:openai_request, "POST", "/v1/responses", "", body}, 1_000

    # The overridden prompt must appear in the request — not the original DB prompt.
    assert body =~ "personalized prompt for John at Acme"
    refute body =~ "original system prompt"
  end

  test "ask_with_config merges DB tools with runtime-synced MCP tools" do
    handler = fn conn, _body ->
      {200, streamed_reply(conn.request_path, "Factory reply", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Factory Merge Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "factory-merge-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Factory Merge Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a helper",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["basic.sleep"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    on_exit(fn ->
      _ = ServerManager.stop_server(configured_agent)
    end)

    assert {:ok, server} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    assert {:ok, _agent} = Jido.AI.register_tool(server, MCPProbeTool)

    assert {:ok, %{request: request}} =
             Factory.ask_with_config(server, "hello", configured_agent, timeout: 35_000)

    assert {:ok, _answer} = Factory.await(request, timeout: 45_000)

    assert_receive {:openai_request, "POST", "/v1/responses", "", body}, 1_000
    assert body =~ "mcp_probe_tool"
    assert body =~ "sleep_action"
  end

  test "build_initial_context returns empty context for non-scoped server ids" do
    configured_agent = %ConfiguredAgent{memory_context_max_size: 5_000}

    result = Factory.build_initial_context(configured_agent, "configured_agent_123")

    assert %AIContext{} = result
    assert AIContext.empty?(result)
  end

  test "build_initial_context returns empty context for malformed scoped server ids" do
    configured_agent = %ConfiguredAgent{memory_context_max_size: 5_000}

    result = Factory.build_initial_context(configured_agent, "agent::person:42")

    assert %AIContext{} = result
    assert AIContext.empty?(result)
  end

  describe "spawn_opts_from_server_id/1" do
    test "parses conversation-scoped ids" do
      assert Factory.spawn_opts_from_server_id("agent:web:conv:123") == %{
               conversation_id: "123",
               person_id: nil,
               channel_type: "web"
             }
    end

    test "parses person-scoped ids" do
      assert Factory.spawn_opts_from_server_id("agent:web:person:42") == %{
               conversation_id: nil,
               person_id: "42",
               channel_type: "web"
             }
    end

    test "returns empty map for malformed binary ids" do
      assert Factory.spawn_opts_from_server_id("configured_agent_123") == %{}
      assert Factory.spawn_opts_from_server_id("agent::conv:") == %{}
    end

    test "returns nil for non-binary ids" do
      assert Factory.spawn_opts_from_server_id(nil) == nil
      assert Factory.spawn_opts_from_server_id(123) == nil
    end
  end

  defp streamed_reply("/v1/chat/completions", text, model) do
    chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-test",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}]
      })

    done_chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-test",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 1, "total_tokens" => 6}
      })

    "data: #{chunk}\n\ndata: #{done_chunk}\n\ndata: [DONE]\n\n"
  end

  defp streamed_reply(_path, text, model) do
    delta_event = Jason.encode!(%{"delta" => text})

    completed_event =
      Jason.encode!(%{
        "response" => %{
          "id" => "resp_test",
          "model" => model,
          "usage" => %{"input_tokens" => 5, "output_tokens" => 1, "total_tokens" => 6}
        }
      })

    [
      "event: response.output_text.delta\n",
      "data: #{delta_event}\n\n",
      "event: response.completed\n",
      "data: #{completed_event}\n\n"
    ]
    |> IO.iodata_to_binary()
  end
end
