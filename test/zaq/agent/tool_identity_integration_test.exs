defmodule Zaq.Agent.ToolIdentityIntegrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Accounts.People
  alias Zaq.Agent.{Executor, ServerManager}
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.TestSupport.{IntegrationAgent, ToolCallingLLMStub}

  defmodule IdentityProbe do
    use Jido.Action,
      name: "identity_probe",
      description: "Report which trusted caller identity fields the tool receives",
      schema: Zoi.object(%{probe: Zoi.boolean()})

    @impl true
    def run(%{probe: true}, context) do
      {:ok,
       %{
         actor: context[:actor],
         has_flat_identity: Map.has_key?(context, :person_id) or Map.has_key?(context, :team_ids)
       }}
    end
  end

  test "a configured agent tool receives the execution actor and neither flat identity key" do
    {:ok, person} = People.create_person(%{full_name: "Tool caller"})
    {:ok, team} = People.create_team(%{name: "Tool caller team"})
    actor = %{person: %{id: person.id, full_name: person.full_name, team_ids: [team.id]}}
    scope = "tool-identity-#{Ecto.UUID.generate()}"

    routes = [
      %{match: fn _ -> true end, tool: "identity_probe", arguments: fn _ -> %{probe: true} end}
    ]

    {child, endpoint} = ToolCallingLLMStub.server(routes, final_response: "Identity checked.")
    start_supervised!(child)
    agent = IntegrationAgent.create!(endpoint, scope, "Use the identity probe.", [])

    assert {:ok, server} =
             ServerManager.ensure_server(agent, "#{agent.name}:#{scope}", nil, actor: actor)

    assert {:ok, _} = Jido.AI.register_tool(server, IdentityProbe)

    incoming = %Incoming{content: "Check identity", channel_id: scope, provider: :web}

    outgoing =
      Executor.run(incoming,
        agent_id: to_string(agent.id),
        scope: scope,
        event: Event.new(incoming, :agent, actor: actor),
        person_id: person.id,
        team_ids: [team.id]
      )

    assert_received {:llm_tool_call, "identity_probe", %{"probe" => true}}
    assert_received {:llm_tool_result, "identity_probe", %{"ok" => true, "result" => result}}

    assert result == %{
             "actor" => Jason.decode!(Jason.encode!(actor)),
             "has_flat_identity" => false
           }

    assert outgoing.metadata.error == false
    assert outgoing.body == "Identity checked."
    refute_received {:llm_stub_error, _}
  end
end
