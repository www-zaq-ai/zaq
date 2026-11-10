defmodule Zaq.TestSupport.IntegrationAgent do
  @moduledoc """
  Creates a configured agent for a local LLM endpoint and owns its runtime cleanup.

  Call from an ExUnit test/setup process with database sandbox access. The scope
  must be unique to the test and match the scope passed to Executor. Routes, stub
  startup, tool assertions and completion waits remain the caller's responsibility.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Zaq.SystemConfigFixtures, only: [ai_credential_fixture: 1]

  alias Zaq.Agent
  alias Zaq.Agent.ServerManager

  @doc "Creates a ReAct agent and registers monitored shutdown for its scoped runtime."
  def create!(endpoint, scope, job, tool_keys) do
    credential =
      ai_credential_fixture(%{
        name: "LLM #{scope}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Agent #{scope}",
        job: job,
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        active: true,
        enabled_tool_keys: tool_keys,
        conversation_enabled: false,
        model_max_context_tokens: 128_000,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn ->
      case Jido.AgentServer.whereis(Jido.registry_name(Zaq.Agent.Jido), "#{agent.name}:#{scope}") do
        nil ->
          :ok

        pid ->
          ref = Process.monitor(pid)
          # This helper owns fixture teardown, after the scenario assertions.
          # Stop its supervised child directly instead of applying the runtime's
          # graceful-drain delay to retained, already-completed requests.
          assert DynamicSupervisor.terminate_child(Zaq.Agent.AgentServerSupervisor, pid) in [
                   :ok,
                   {:error, :not_found}
                 ]

          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
          :ok = ServerManager.stop_server(agent)
      end
    end)

    agent
  end
end
