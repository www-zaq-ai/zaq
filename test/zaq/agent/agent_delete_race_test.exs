defmodule Zaq.AgentDeleteRaceTest do
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Agent
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.IncomingMessageRouting
  alias Zaq.Engine.IncomingMessageRoutingRule
  alias Zaq.Repo

  test "delete_agent detects a global routing rule inserted after its first usage check" do
    credential =
      ai_credential_fixture(%{
        name: "Delete Race Credential #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai"
      })

    {:ok, agent} =
      Agent.create_agent(%{
        name: "Delete Race Agent #{System.unique_integer([:positive])}",
        job: "job",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: [],
        conversation_enabled: true
      })

    manager = Process.whereis(ServerManager)
    assert is_pid(manager)
    assert {:flags, []} = :erlang.trace_info(manager, :flags)

    on_exit(fn ->
      try do
        if Process.alive?(manager), do: :sys.resume(manager)
      catch
        _, _ -> :ok
      after
        :erlang.trace(manager, false, [:receive])
      end
    end)

    :ok = :sys.suspend(manager)
    :erlang.trace(manager, true, [:receive])

    task_supervisor = start_supervised!(Task.Supervisor)
    task = Task.Supervisor.async_nolink(task_supervisor, fn -> Agent.delete_agent(agent) end)
    Sandbox.allow(Repo, self(), task.pid)

    assert_receive {:trace, ^manager, :receive, {:"$gen_call", _from, {:stop_server, ^agent}}},
                   3_000

    assert {:ok, rule} =
             IncomingMessageRouting.upsert_rule(%{}, %{
               routing_mode: :agent,
               configured_agent_id: agent.id
             })

    :ok = :sys.resume(manager)

    assert {:error, changeset} = Task.await(task, 3_000)
    assert errors_on(changeset).base == ["Agent is in use by:\n- incoming routing global default"]
    assert Repo.get!(Agent.ConfiguredAgent, agent.id).id == agent.id
    assert Repo.get!(IncomingMessageRoutingRule, rule.id).id == rule.id
  end
end
