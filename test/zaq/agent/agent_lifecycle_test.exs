defmodule Zaq.Agent.AgentLifecycleTest do
  # The singleton ServerManager performs DB reads during initialization; it
  # cannot be shared by independent async sandbox owners.
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.ServerManager

  test "delete_agent/1 stops the runtime server before removing the record" do
    credential =
      ai_credential_fixture(%{
        name: "Delete Runtime Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: "https://api.openai.com/v1",
        api_key: "x"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Delete Runtime Agent #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: false,
        active: true,
        advanced_options: %{}
      })

    on_exit(fn -> ServerManager.stop_server(agent) end)

    assert {:ok, server_ref} =
             ServerManager.ensure_server(agent, "configured_agent_#{agent.id}", nil,
               actor: %{kind: :system, subject: "agent-test"}
             )

    assert {:via, Registry, {registry, key}} = server_ref
    pid = Jido.AgentServer.whereis(registry, key)
    assert is_pid(pid)
    monitor_ref = Process.monitor(pid)

    assert {:ok, _deleted} = Agent.delete_agent(agent)
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, _reason}, 3_000
    refute Process.alive?(pid)
    assert Agent.get_agent(agent.id) == nil
  end
end
