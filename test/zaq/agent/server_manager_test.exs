defmodule Zaq.Agent.ServerManagerTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Factory
  alias Zaq.Agent.MCP
  alias Zaq.Agent.ServerManager
  alias Zaq.TestSupport.OpenAIStub

  defmodule StubRuntimeSync do
    def sync_agent_runtime(agent, server_ref, opts \\ []) do
      notify_pid = Keyword.get(opts, :notify_pid)

      if is_pid(notify_pid) do
        send(
          notify_pid,
          {:runtime_sync_hydrate_called, agent.id, agent.enabled_mcp_endpoint_ids, server_ref}
        )
      end

      {:ok,
       %{
         tools: %{added_tools: [], removed_tools: [], add_results: [], remove_results: []},
         mcp: %{synced_endpoint_ids: [], skipped_endpoint_ids: [], warnings: [], results: []}
       }}
    end
  end

  defmodule StubRuntimeSyncWarn do
    def sync_agent_runtime(_agent, _server_ref, _opts \\ []) do
      {:ok,
       %{
         tools: %{added_tools: [], removed_tools: [], add_results: [], remove_results: []},
         mcp: %{
           synced_endpoint_ids: [],
           skipped_endpoint_ids: [],
           warnings: ["warn"],
           results: []
         }
       }}
    end
  end

  defmodule StubRuntimeSyncUnexpected do
    def sync_agent_runtime(_agent, _server_ref, _opts \\ []), do: {:ok, %{unexpected: true}}
  end

  defmodule StubRuntimeSyncError do
    def sync_agent_runtime(_agent, _server_ref, _opts \\ []), do: {:error, :runtime_sync_failed}
  end

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

    assert {:ok, server_ref} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    refute is_binary(server_ref)

    assert {:via, Registry, {registry, key}} = server_ref
    assert registry == Jido.registry_name(Zaq.Agent.Jido)
    assert key == Agent.agent_server_id(configured_agent.id)

    assert {:ok, status} = Jido.AgentServer.status(server_ref)

    assert %{provider: :openai, id: "gpt-4.1-mini", base_url: "https://api.openai.com/v1"} =
             status.raw_state.model

    assert status.raw_state.runtime_config.system_prompt == "You are a test agent"
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

    assert {:ok, server_ref} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    assert {:via, Registry, {_registry, _key}} = server_ref

    assert {:ok, status} = Jido.AgentServer.status(server_ref)

    assert status.raw_state.model == %{
             provider: :openai,
             id: "deepseek/deepseek-r1-0528",
             base_url: "https://api.novita.ai/openai/v1"
           }
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

    assert {:ok, server_ref_1} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    assert {:ok, server_ref_2} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

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
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    pid_before = Jido.AgentServer.whereis(registry, key)
    assert is_pid(pid_before)

    {:ok, updated_agent} =
      Agent.update_agent(configured_agent, %{
        job: "Prompt v2",
        advanced_options: %{"temperature" => 0.1}
      })

    assert {:ok, _server_ref} =
             ServerManager.ensure_server(updated_agent, "configured_agent_#{updated_agent.id}")

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
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    pid = Jido.AgentServer.whereis(registry, key)
    assert is_pid(pid)
    monitor_ref = Process.monitor(pid)

    assert :ok = ServerManager.stop_server(configured_agent)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 1_000
  end

  test "init starts no servers — supervision tree is empty on start" do
    # init/1 no longer pre-spawns any servers; all spawning is lazy per-message.
    assert {:ok, state} = ServerManager.init([])

    assert state == %{
             fingerprints: %{},
             agent_servers: %{},
             server_to_agent: %{},
             draining: %{},
             monitors: %{}
           }
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

    assert {:ok, server_ref} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    assert {:ok, status} = Jido.AgentServer.status(server_ref)
    model = status.raw_state.model
    assert %{provider: :openai, id: "gpt-4.1-mini"} = model
    assert Map.get(model, :base_url) == credential.endpoint
    refute Map.has_key?(model, :api_key)

    _ = ServerManager.stop_server(configured_agent)
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

    init_state = %{
      fingerprints: %{},
      agent_servers: %{},
      server_to_agent: %{},
      draining: %{},
      monitors: %{}
    }

    server_id = "configured_agent_123456"

    assert {:reply, {:error, :provider_not_found}, ^init_state} =
             ServerManager.handle_call(
               {:ensure_server, configured_agent, server_id, nil},
               self(),
               init_state
             )
  end

  test "start_link returns already_started when manager is running" do
    assert {:error, {:already_started, pid}} = ServerManager.start_link([])
    assert is_pid(pid)
  end

  test "ensure_answering_server/1 no longer exists" do
    refute function_exported?(ServerManager, :ensure_answering_server, 1)
  end

  describe "init/1 starts no servers" do
    test "supervision tree is empty after start" do
      # init/1 must not pre-spawn any servers; all children belong to other tests.
      # We call init/1 directly to inspect the state without side effects.
      assert {:ok, state} = ServerManager.init([])

      assert state == %{
               fingerprints: %{},
               agent_servers: %{},
               server_to_agent: %{},
               draining: %{},
               monitors: %{}
             }
    end
  end

  describe "ensure_server/2" do
    test "starts server with the given scope id and returns a ref" do
      credential =
        ai_credential_fixture(%{
          name: "OpenAI Credential #{System.unique_integer([:positive, :monotonic])}",
          provider: "openai",
          endpoint: "https://api.openai.com/v1",
          api_key: "x"
        })

      {:ok, configured_agent} =
        Agent.create_agent(%{
          name: "Server By Id Agent #{System.unique_integer([:positive])}",
          description: "",
          job: "by id test",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: [],
          conversation_enabled: false,
          active: true,
          advanced_options: %{}
        })

      server_id = "configured_agent_#{configured_agent.id}:person_42"

      assert {:ok, ref} = ServerManager.ensure_server(configured_agent, server_id)
      assert {:via, Registry, {_registry, ^server_id}} = ref
    end
  end

  describe "stop_server/2" do
    test "terminates the scoped server process" do
      credential =
        ai_credential_fixture(%{
          name: "Scoped Stop Credential #{System.unique_integer([:positive, :monotonic])}",
          provider: "openai",
          endpoint: "https://api.openai.com/v1",
          api_key: "x"
        })

      {:ok, configured_agent} =
        Agent.create_agent(%{
          name: "Scoped Stop Agent #{System.unique_integer([:positive])}",
          description: "",
          job: "stop scope",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: [],
          conversation_enabled: false,
          active: true,
          advanced_options: %{}
        })

      server_id = "configured_agent_#{configured_agent.id}:scope_stop"

      assert {:ok, {:via, Registry, {registry, ^server_id}}} =
               ServerManager.ensure_server(configured_agent, server_id)

      pid = Jido.AgentServer.whereis(registry, server_id)
      assert is_pid(pid)
      monitor_ref = Process.monitor(pid)

      assert :ok = ServerManager.stop_server(configured_agent, server_id)
      assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 1_000
    end
  end

  test "concurrent ensure_server calls reuse the same runtime pid" do
    credential =
      ai_credential_fixture(%{
        name: "Concurrent Ensure Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Concurrent Ensure Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "concurrent",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    refs =
      1..8
      |> Task.async_stream(
        fn _ ->
          ServerManager.ensure_server(configured_agent, "configured_agent_#{configured_agent.id}")
        end,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, {:ok, ref}} -> ref end)

    [first_ref | rest] = refs
    assert Enum.all?(rest, &(&1 == first_ref))

    assert {:via, Registry, {registry, key}} = first_ref
    pid = Jido.AgentServer.whereis(registry, key)
    assert is_pid(pid)
  end

  test "runtime hydration happens when server is first ensured, not during init" do
    previous_module = Application.get_env(:zaq, :agent_runtime_sync_module)
    previous_opts = Application.get_env(:zaq, :agent_runtime_sync_opts)

    Application.put_env(:zaq, :agent_runtime_sync_module, StubRuntimeSync)
    Application.put_env(:zaq, :agent_runtime_sync_opts, notify_pid: self())

    on_exit(fn ->
      if is_nil(previous_module) do
        Application.delete_env(:zaq, :agent_runtime_sync_module)
      else
        Application.put_env(:zaq, :agent_runtime_sync_module, previous_module)
      end

      if is_nil(previous_opts) do
        Application.delete_env(:zaq, :agent_runtime_sync_opts)
      else
        Application.put_env(:zaq, :agent_runtime_sync_opts, previous_opts)
      end
    end)

    credential =
      ai_credential_fixture(%{
        name: "Hydrate Init Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, endpoint} =
      MCP.create_mcp_endpoint(%{
        name: "Hydrate Endpoint #{System.unique_integer([:positive])}",
        type: "remote",
        status: "enabled",
        timeout_ms: 5000,
        url: "http://localhost:8000/mcp"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Hydrate Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "hydrate",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        enabled_mcp_endpoint_ids: [endpoint.id],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, _state} = ServerManager.init([])

    refute_receive {:runtime_sync_hydrate_called, _, _, _}, 150

    assert {:ok, _server_ref} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    assert_receive {:runtime_sync_hydrate_called, agent_id, endpoint_ids, _server_ref}, 1_000
    assert agent_id == configured_agent.id
    assert endpoint_ids == [endpoint.id]
  end

  test "sync_runtime returns ok with runtime when sync emits warnings" do
    previous_module = Application.get_env(:zaq, :agent_runtime_sync_module)

    Application.put_env(:zaq, :agent_runtime_sync_module, StubRuntimeSyncWarn)

    on_exit(fn ->
      if is_nil(previous_module) do
        Application.delete_env(:zaq, :agent_runtime_sync_module)
      else
        Application.put_env(:zaq, :agent_runtime_sync_module, previous_module)
      end
    end)

    credential =
      ai_credential_fixture(%{
        name: "Sync Runtime Warn Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Sync Runtime Warn Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "sync warn",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, _server_ref} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    assert {:ok, %{server_ref: {:via, Registry, _}, runtime: runtime}} =
             ServerManager.sync_runtime(configured_agent)

    assert runtime.mcp.warnings == ["warn"]
  end

  test "sync_runtime returns ok when runtime sync returns an unexpected payload shape" do
    previous_module = Application.get_env(:zaq, :agent_runtime_sync_module)

    Application.put_env(:zaq, :agent_runtime_sync_module, StubRuntimeSyncUnexpected)

    on_exit(fn ->
      if is_nil(previous_module) do
        Application.delete_env(:zaq, :agent_runtime_sync_module)
      else
        Application.put_env(:zaq, :agent_runtime_sync_module, previous_module)
      end
    end)

    credential =
      ai_credential_fixture(%{
        name:
          "Sync Runtime Unexpected Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Sync Runtime Unexpected Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "sync unexpected",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, _server_ref} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    assert {:ok, %{server_ref: {:via, Registry, _}, runtime: %{unexpected: true}}} =
             ServerManager.sync_runtime(configured_agent)
  end

  test "sync_runtime returns error when runtime sync fails" do
    previous_module = Application.get_env(:zaq, :agent_runtime_sync_module)

    Application.put_env(:zaq, :agent_runtime_sync_module, StubRuntimeSyncError)

    on_exit(fn ->
      if is_nil(previous_module) do
        Application.delete_env(:zaq, :agent_runtime_sync_module)
      else
        Application.put_env(:zaq, :agent_runtime_sync_module, previous_module)
      end
    end)

    credential =
      ai_credential_fixture(%{
        name: "Sync Runtime Error Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Sync Runtime Error Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "sync error",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, _server_ref} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    assert {:error, :runtime_sync_failed} = ServerManager.sync_runtime(configured_agent)
  end

  test "sync_runtime ignores invalid runtime sync opts env and falls back to []" do
    previous_module = Application.get_env(:zaq, :agent_runtime_sync_module)
    previous_opts = Application.get_env(:zaq, :agent_runtime_sync_opts)

    Application.put_env(:zaq, :agent_runtime_sync_module, StubRuntimeSync)
    Application.put_env(:zaq, :agent_runtime_sync_opts, :invalid_opts)

    on_exit(fn ->
      if is_nil(previous_module) do
        Application.delete_env(:zaq, :agent_runtime_sync_module)
      else
        Application.put_env(:zaq, :agent_runtime_sync_module, previous_module)
      end

      if is_nil(previous_opts) do
        Application.delete_env(:zaq, :agent_runtime_sync_opts)
      else
        Application.put_env(:zaq, :agent_runtime_sync_opts, previous_opts)
      end
    end)

    credential =
      ai_credential_fixture(%{
        name:
          "Sync Runtime Invalid Opts Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Sync Runtime Invalid Opts Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "sync opts fallback",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, _server_ref} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    assert {:ok, %{runtime: runtime}} = ServerManager.sync_runtime(configured_agent)
    assert runtime.mcp.warnings == []
  end

  test "stop_server/1 stops all tracked servers for configured agent" do
    credential =
      ai_credential_fixture(%{
        name: "Integer Stop Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Integer Stop Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "stop integer",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    assert {:ok, {:via, Registry, {registry, key}}} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )

    pid = Jido.AgentServer.whereis(registry, key)
    assert is_pid(pid)
    monitor_ref = Process.monitor(pid)

    assert :ok = ServerManager.stop_server(configured_agent)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 1_000
  end

  test "sync_runtime returns error when ensure_server cannot build model" do
    configured_agent = %ConfiguredAgent{
      id: 889_001,
      name: "Sync Runtime Provider Error",
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

    assert {:error, :provider_not_found} =
             ServerManager.ensure_server(
               configured_agent,
               "configured_agent_#{configured_agent.id}"
             )
  end

  test "ensure_server/2 is idempotent for unchanged config on same scope" do
    credential =
      ai_credential_fixture(%{
        name: "By Id Idempotent Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "By Id Idempotent Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "idempotent",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    server_id = "configured_agent_#{configured_agent.id}:channel_99"

    assert {:ok, ref1} = ServerManager.ensure_server(configured_agent, server_id)
    assert {:ok, ref2} = ServerManager.ensure_server(configured_agent, server_id)
    assert ref1 == ref2

    assert {:via, Registry, {registry, ^server_id}} = ref1
    pid1 = Jido.AgentServer.whereis(registry, server_id)
    pid2 = Jido.AgentServer.whereis(registry, server_id)
    assert is_pid(pid1)
    assert pid1 == pid2
  end

  describe "history context injection on cold spawn" do
    alias Jido.AI.Context, as: AIContext
    alias Zaq.Accounts.Person
    alias Zaq.Engine.Conversations.{Conversation, Message}
    alias Zaq.Engine.Messages.Incoming
    alias Zaq.Repo

    defp insert_person_for_sm do
      Repo.insert!(%Person{
        full_name: "SM Test Person #{System.unique_integer([:positive])}",
        status: "active"
      })
    end

    defp insert_conversation_for_sm(person_id, channel_type) do
      %Conversation{}
      |> Conversation.changeset(%{
        channel_user_id: "user_#{System.unique_integer([:positive])}",
        channel_type: channel_type,
        person_id: person_id,
        status: "active"
      })
      |> Repo.insert!()
    end

    defp insert_message_for_sm(conversation, role, content) do
      Repo.insert!(
        struct(Message, %{
          conversation_id: conversation.id,
          role: role,
          content: content,
          inserted_at: DateTime.utc_now()
        })
      )
    end

    defp make_agent_for_routing(name_suffix) do
      credential =
        ai_credential_fixture(%{
          name: "Routing Cred #{name_suffix} #{System.unique_integer([:positive, :monotonic])}",
          provider: "openai",
          endpoint: "https://api.openai.com/v1",
          api_key: "x"
        })

      {:ok, configured_agent} =
        Agent.create_agent(%{
          name: "Routing Agent #{name_suffix} #{System.unique_integer([:positive])}",
          description: "",
          job: "routing test",
          model: "gpt-4.1-mini",
          credential_id: credential.id,
          strategy: "react",
          enabled_tool_keys: [],
          conversation_enabled: false,
          active: true,
          advanced_options: %{}
        })

      configured_agent
    end

    test "injects conversation history when incoming carries conversation_id" do
      person = insert_person_for_sm()
      conv = insert_conversation_for_sm(person.id, "bo")
      insert_message_for_sm(conv, "user", "hello from this conversation")

      configured_agent = make_agent_for_routing("HistConv")
      server_id = "routing_conv_test_#{System.unique_integer([:positive])}"

      incoming = %Incoming{
        content: "q",
        channel_id: "c",
        provider: :web,
        person_id: person.id,
        metadata: %{conversation_id: conv.id}
      }

      assert {:ok, server_ref} =
               ServerManager.ensure_server(configured_agent, server_id, incoming)

      assert {:ok, status} = Jido.AgentServer.status(server_ref)
      messages = AIContext.to_messages(status.raw_state.context)

      assert Enum.any?(messages, fn m ->
               String.ends_with?(m.content, "hello from this conversation")
             end)
    end

    test "injects person+channel history when incoming has person_id but no conversation_id" do
      person = insert_person_for_sm()
      conv = insert_conversation_for_sm(person.id, "bo")
      insert_message_for_sm(conv, "user", "person-channel message")

      configured_agent = make_agent_for_routing("HistPerson")
      server_id = "routing_person_test_#{System.unique_integer([:positive])}"

      incoming = %Incoming{
        content: "q",
        channel_id: "c",
        provider: :web,
        person_id: person.id
      }

      assert {:ok, server_ref} =
               ServerManager.ensure_server(configured_agent, server_id, incoming)

      assert {:ok, status} = Jido.AgentServer.status(server_ref)
      messages = AIContext.to_messages(status.raw_state.context)

      assert Enum.any?(messages, fn m ->
               String.ends_with?(m.content, "person-channel message")
             end)
    end
  end

  test "drain timeout kills in-flight server and next message uses replacement pid" do
    previous_timeout = Application.get_env(:zaq, :agent_server_drain_timeout_ms)
    previous_force_drain = Application.get_env(:zaq, :agent_server_force_drain)
    Application.put_env(:zaq, :agent_server_drain_timeout_ms, 200)
    Application.put_env(:zaq, :agent_server_force_drain, true)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:zaq, :agent_server_drain_timeout_ms)
      else
        Application.put_env(:zaq, :agent_server_drain_timeout_ms, previous_timeout)
      end

      if is_nil(previous_force_drain) do
        Application.delete_env(:zaq, :agent_server_force_drain)
      else
        Application.put_env(:zaq, :agent_server_force_drain, previous_force_drain)
      end
    end)

    handler = fn conn, body ->
      payload = Jason.decode!(body)
      content = extract_request_content(payload)

      if String.contains?(content, "SLOW_REQUEST") do
        Process.sleep(10_000)
      end

      {200, streamed_reply(conn.request_path, "ok", "gpt-4.1-mini")}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Drain Timeout Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "drain-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Drain Timeout Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "You are a helper",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    server_id = "configured_agent_#{configured_agent.id}:drain_timeout"

    assert {:ok, server_ref} = ServerManager.ensure_server(configured_agent, server_id)
    assert {:via, Registry, {registry, ^server_id}} = server_ref

    pid_before = Jido.AgentServer.whereis(registry, server_id)
    assert is_pid(pid_before)

    parent = self()

    {:ok, _slow_pid} =
      Task.start(fn ->
        result =
          try do
            case Factory.ask_with_config(
                   server_ref,
                   "SLOW_REQUEST",
                   configured_agent,
                   timeout: 15_000
                 ) do
              {:ok, request} -> Factory.await(request, timeout: 20_000)
              error -> error
            end
          catch
            :exit, reason -> {:exit, reason}
          end

        send(parent, {:slow_result, result})
      end)

    Process.sleep(50)

    assert :ok = ServerManager.stop_server(configured_agent, server_id)

    monitor_ref = Process.monitor(pid_before)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid_before, _reason}, 2_000

    assert_receive {:slow_result, slow_result}, 21_000
    assert match?({:error, _}, slow_result) or match?({:exit, _}, slow_result)

    assert {:ok, server_ref_after} = ServerManager.ensure_server(configured_agent, server_id)
    assert {:via, Registry, {registry, ^server_id}} = server_ref_after

    pid_after = Jido.AgentServer.whereis(registry, server_id)
    assert is_pid(pid_after)
    refute pid_after == pid_before

    assert {:ok, request} =
             Factory.ask_with_config(server_ref_after, "FAST_REQUEST", configured_agent,
               timeout: 15_000
             )

    assert {:ok, _answer} = Factory.await(request, timeout: 20_000)
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

  defp extract_request_content(%{"input" => input}) when is_list(input) do
    input
    |> Enum.flat_map(fn
      %{"content" => content} when is_list(content) ->
        Enum.map(content, fn
          %{"text" => text} when is_binary(text) -> text
          _ -> ""
        end)

      %{"content" => content} when is_binary(content) ->
        [content]

      _ ->
        []
    end)
    |> Enum.join(" ")
  end

  defp extract_request_content(%{"messages" => messages}) when is_list(messages) do
    messages
    |> Enum.map_join(" ", fn
      %{"content" => content} when is_binary(content) -> content
      %{"content" => content} when is_list(content) -> inspect(content)
      _ -> ""
    end)
  end

  defp extract_request_content(_), do: ""
end
