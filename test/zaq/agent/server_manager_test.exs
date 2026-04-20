defmodule Zaq.Agent.ServerManagerTest do
  use Zaq.DataCase, async: false

  import ExUnit.CaptureLog
  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.ServerManager

  test "ensure_server returns a resolvable server reference" do
    credential =
      ai_credential_fixture(%{
        name: "OpenAI Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Server Ref Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a test agent",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, server_ref} = ServerManager.ensure_server(configured_agent)
    refute is_binary(server_ref)

    assert {:via, Registry, {registry, key}} = server_ref
    assert registry == Jido.registry_name(Zaq.Agent.Jido)
    assert key == Agent.agent_server_id(configured_agent.id)

    assert {:ok, status} = Jido.AgentServer.status(server_ref)
    assert {:openai, opts} = status.raw_state.model
    assert Keyword.get(opts, :model) == "gpt-4.1-mini"
  end

  test "ensure_server supports catalog-only provider via openai runtime fallback" do
    credential =
      ai_credential_fixture(%{
        name: "Novita Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "novita_ai",
        endpoint: "https://api.novita.ai/openai/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Server Ref Novita Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a test agent",
        model: "deepseek/deepseek-r1-0528",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, server_ref} = ServerManager.ensure_server(configured_agent)
    assert {:via, Registry, {_registry, _key}} = server_ref

    assert {:ok, status} = Jido.AgentServer.status(server_ref)
    assert status.raw_state.model == %{provider: :openai, id: "deepseek/deepseek-r1-0528"}
  end

  test "ensure_server is idempotent for unchanged agent config" do
    credential =
      ai_credential_fixture(%{
        name: "OpenAI Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Server Idempotent Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are idempotent",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, server_ref_1} = ServerManager.ensure_server(configured_agent)
    assert {:ok, server_ref_2} = ServerManager.ensure_server(configured_agent)
    assert server_ref_1 == server_ref_2

    assert {:via, Registry, {registry, key}} = server_ref_1
    pid_1 = Jido.AgentServer.whereis(registry, key)
    pid_2 = Jido.AgentServer.whereis(registry, key)

    assert is_pid(pid_1)
    assert pid_1 == pid_2
  end

  test "ensure_server restarts when agent fingerprint changes" do
    credential =
      ai_credential_fixture(%{
        name: "OpenAI Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Server Restart Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "Prompt v1",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, {:via, Registry, {registry, key}}} =
             ServerManager.ensure_server(configured_agent)

    pid_before = Jido.AgentServer.whereis(registry, key)
    assert is_pid(pid_before)

    {:ok, updated_agent} =
      Agent.update_agent(configured_agent, %{
        job: "Prompt v2",
        advanced_options: %{"temperature" => 0.1}
      })

    assert {:ok, _server_ref} = ServerManager.ensure_server(updated_agent)
    pid_after = Jido.AgentServer.whereis(registry, key)

    assert is_pid(pid_after)
    refute pid_before == pid_after
  end

  test "stop_server accepts string id and removes runtime server" do
    credential =
      ai_credential_fixture(%{
        name: "OpenAI Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Server Stop Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "stop test",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, {:via, Registry, {registry, key}}} =
             ServerManager.ensure_server(configured_agent)

    pid = Jido.AgentServer.whereis(registry, key)
    assert is_pid(pid)
    monitor_ref = Process.monitor(pid)

    assert :ok = ServerManager.stop_server(to_string(configured_agent.id))
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 1_000
  end

  test "init logs and continues when an active agent cannot start" do
    credential =
      ai_credential_fixture(%{
        name: "Invalid Provider Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "provider_not_found_zaq"
      })

    {:ok, _agent} =
      Zaq.Repo.insert(%Zaq.Agent.ConfiguredAgent{
        name: "Invalid Runtime Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, state} = ServerManager.init([])
        assert is_map(state)
      end)

    assert log =~ "Failed to start configured agent"
  end

  test "ensure_server uses credential lookup when credential is not preloaded" do
    credential =
      ai_credential_fixture(%{
        name: "OpenAI Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: nil
      })

    configured_agent = %ConfiguredAgent{
      id: System.unique_integer([:positive]),
      name: "Lookup Credential Agent",
      job: "You are a helper",
      model: "gpt-4.1-mini",
      credential_id: credential.id,
      credential: nil,
      strategy: "react",
      enabled_tool_keys: [],
      conversation_enabled: false,
      active: true,
      advanced_options: %{}
    }

    assert {:ok, server_ref} = ServerManager.ensure_server(configured_agent)
    assert {:ok, status} = Jido.AgentServer.status(server_ref)
    assert {:openai, opts} = status.raw_state.model
    assert Keyword.get(opts, :model) == "gpt-4.1-mini"
    assert Keyword.get(opts, :base_url) == credential.endpoint
    refute Keyword.has_key?(opts, :api_key)

    _ = ServerManager.stop_server(configured_agent.id)
  end

  test "handle_call returns error tuple when ensure_server model resolution fails" do
    configured_agent = %ConfiguredAgent{
      id: 123_456,
      name: "Direct HandleCall Agent",
      job: "job",
      model: "gpt-4.1-mini",
      credential: %{provider: "provider_not_found_zaq"},
      credential_id: nil,
      strategy: "react",
      enabled_tool_keys: [],
      conversation_enabled: false,
      active: true,
      advanced_options: %{}
    }

    assert {:reply, {:error, :provider_not_found}, %{}} =
             ServerManager.handle_call({:ensure_server, configured_agent}, self(), %{})
  end

  test "handle_call stop_server raises for invalid string ids" do
    assert_raise ArgumentError, ~r/invalid configured agent id/, fn ->
      ServerManager.handle_call({:stop_server, "not-an-id"}, self(), %{})
    end
  end

  test "start_link returns already_started when manager is running" do
    assert {:error, {:already_started, pid}} = ServerManager.start_link([])
    assert is_pid(pid)
  end

  test "ensure_server returns system prompt config failure when prompt cannot be configured" do
    configured_agent = %ConfiguredAgent{
      id: System.unique_integer([:positive]),
      name: "Config Failure Agent",
      job: nil,
      model: "gpt-4.1-mini",
      credential: %{provider: "openai", endpoint: "https://api.openai.com/v1", api_key: "x"},
      credential_id: nil,
      strategy: "react",
      enabled_tool_keys: [],
      conversation_enabled: false,
      active: true,
      advanced_options: %{}
    }

    assert {:reply, {:error, :system_prompt_config_failed}, %{}} =
             ServerManager.handle_call({:ensure_server, configured_agent}, self(), %{})

    _ = ServerManager.stop_server(configured_agent.id)
  end
end
