defmodule Zaq.Agent.FactoryRuntimeFailureTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Jido.AI.Actions.Skill.LoadResource
  alias Jido.AI.Actions.Skill.LoadSkill
  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Factory
  alias Zaq.Agent.ProviderSpec
  alias Zaq.Agent.Skills
  alias Zaq.TestSupport.OpenAIStub

  @execution_actor %{kind: :system, subject: "factory-runtime-failure-test"}

  defmodule ScriptedServerProxy do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call(:get_state, _from, state) do
      case state_read(state) do
        {:ok, result, state} -> {:reply, result, state}
        {:error, result, state} -> {:reply, result, state}
      end
    end

    def handle_call(
          {:signal,
           %Jido.Signal{type: "ai.react.set_system_prompt", data: %{system_prompt: prompt}}},
          _from,
          state
        ) do
      send(state.owner, {:prompt_update_attempt, state.test_ref, prompt})
      {:reply, state.prompt_response, state}
    end

    def handle_call(message, _from, state) do
      send(state.owner, {:unexpected_server_message, state.test_ref, message})
      {:reply, {:error, :unexpected_server_message}, state}
    end

    @impl true
    def handle_cast(message, state) do
      send(state.owner, {:unexpected_server_message, state.test_ref, message})
      {:noreply, state}
    end

    defp state_read(%{script: []} = state) do
      send(state.owner, {:proxy_script_depleted, state.test_ref})
      {:error, {:error, :proxy_script_depleted}, state}
    end

    defp state_read(%{script: [entry | rest], backend: backend} = state) do
      state = %{state | script: rest}

      case entry do
        :forward -> {:ok, Jido.AgentServer.state(backend), state}
        {:error, reason} -> {:error, {:error, reason}, state}
      end
    end
  end

  test "ask rejects newly attached skills until their native loaders are registered" do
    %{backend: backend, agent: base_agent} = runtime_fixture()
    {:ok, skill} = create_skill()
    agent = %{base_agent | enabled_skill_ids: [skill.id], job: "Replacement skill prompt"}

    assert {:error, {:runtime_sync_required, ["load_skill", "load_skill_resource"]}} =
             Factory.ask_with_config(backend, "hello", agent)

    assert {:ok, _} = Jido.AI.register_tool(backend, LoadSkill)

    assert {:error, {:runtime_sync_required, ["load_skill_resource"]}} =
             Factory.ask_with_config(backend, "hello", agent)

    assert {:ok, registered} = Jido.AI.list_tools(backend)
    assert LoadSkill in registered
    refute LoadResource in registered
    assert {:ok, status} = Jido.AgentServer.status(backend)
    assert status.raw_state.__strategy__.config.system_prompt == "Original cached prompt"
    refute_received {:openai_request, _, _, _, _}
  end

  test "ask returns runtime sync check failure when tool inspection becomes unavailable" do
    %{backend: backend, agent: base_agent} = runtime_fixture()
    {:ok, skill} = create_skill()
    agent = %{base_agent | enabled_skill_ids: [skill.id]}
    proxy = proxy(backend, [:forward, {:error, :not_found}], {:error, :unused})

    assert {:error, {:runtime_sync_check_failed, :not_found}} =
             Factory.ask_with_config(proxy, "hello", agent)

    refute_received {:proxy_script_depleted, _}
    refute_received {:prompt_update_attempt, _, _}
    refute_received {:unexpected_server_message, _, _}
    refute_received {:openai_request, _, _, _, _}
  end

  test "ask fails after four rejected system prompt updates and never starts generation" do
    %{backend: backend, agent: base_agent} = runtime_fixture()
    agent = %{base_agent | job: "Replacement cached prompt"}
    proxy = proxy(backend, [:forward, :forward], {:error, :prompt_update_rejected})

    assert {:error, :system_prompt_config_failed} =
             Factory.ask_with_config(proxy, "hello", agent)

    refute_received {:proxy_script_depleted, _}
    assert_receive {:prompt_update_attempt, ref, "Replacement cached prompt"}
    assert_receive {:prompt_update_attempt, ^ref, "Replacement cached prompt"}
    assert_receive {:prompt_update_attempt, ^ref, "Replacement cached prompt"}
    assert_receive {:prompt_update_attempt, ^ref, "Replacement cached prompt"}
    refute_received {:prompt_update_attempt, ^ref, _}
    refute_received {:unexpected_server_message, ^ref, _}
    refute_received {:openai_request, _, _, _, _}
  end

  test "ask attempts prompt recovery when current prompt status is unavailable" do
    %{backend: backend, agent: base_agent} = runtime_fixture()
    agent = %{base_agent | job: "Recover missing prompt"}
    proxy = proxy(backend, [:forward, {:error, :not_found}], {:error, :not_found})

    assert {:error, :system_prompt_config_failed} =
             Factory.ask_with_config(proxy, "hello", agent)

    refute_received {:proxy_script_depleted, _}
    assert_receive {:prompt_update_attempt, ref, "Recover missing prompt"}
    assert_receive {:prompt_update_attempt, ^ref, "Recover missing prompt"}
    assert_receive {:prompt_update_attempt, ^ref, "Recover missing prompt"}
    assert_receive {:prompt_update_attempt, ^ref, "Recover missing prompt"}
    refute_received {:prompt_update_attempt, ^ref, _}
    refute_received {:unexpected_server_message, ^ref, _}
    refute_received {:openai_request, _, _, _, _}
  end

  defp runtime_fixture do
    handler = fn _conn, _body ->
      {500, Jason.encode!(%{"error" => "unexpected factory runtime request"})}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, self())
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        provider: "openai",
        endpoint: endpoint,
        api_key: "factory-runtime-test-key"
      })

    agent = %ConfiguredAgent{
      job: "Original cached prompt",
      model: "gpt-4.1-mini",
      enabled_tool_keys: [],
      enabled_skill_ids: [],
      credential_id: credential.id,
      credential: credential,
      advanced_options: %{},
      model_max_context_tokens: 5_000
    }

    assert {:ok, model} = ProviderSpec.build(agent)
    assert {:ok, runtime_config} = Factory.runtime_config(agent, actor: @execution_actor)

    server =
      start_supervised!(
        {Jido.AgentServer,
         agent: Factory,
         jido: Zaq.Agent.Jido,
         registry: Jido.registry_name(Zaq.Agent.Jido),
         id: "factory-runtime-#{Ecto.UUID.generate()}",
         initial_state: %{
           model: model,
           runtime_config: runtime_config,
           execution_actor: @execution_actor,
           tool_context: runtime_config.tool_context,
           context: AIContext.new()
         }}
      )

    assert {:ok, _} = Jido.AI.set_system_prompt(server, "Original cached prompt")
    %{backend: server, agent: agent}
  end

  defp create_skill do
    Skills.create_skill(%{
      name: "factory-sync-#{System.unique_integer([:positive])}",
      description: "Needs native loading",
      body: "Load these instructions when needed.",
      provided_tool_keys: []
    })
  end

  defp proxy(backend, script, prompt_response) do
    start_supervised!(
      {ScriptedServerProxy,
       owner: self(),
       test_ref: make_ref(),
       backend: backend,
       script: script,
       prompt_response: prompt_response}
    )
  end
end
