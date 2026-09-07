defmodule Zaq.TestSupport.IntegrationAgentTest do
  use Zaq.DataCase, async: false

  alias Zaq.TestSupport.IntegrationAgent

  test "creates explicit scenario settings without starting a runtime; cleanup tolerates no runtime" do
    scope = "integration-helper-#{Ecto.UUID.generate()}"
    job = "Report the requested HTTP response."
    tools = ["general.http_request"]

    agent = IntegrationAgent.create!("http://127.0.0.1:1/v1", scope, job, tools)

    assert agent.name == "Agent #{scope}"
    assert agent.job == job
    assert agent.enabled_tool_keys == tools
    assert agent.model == "gpt-4.1-mini"
    assert agent.strategy == "react"
    assert agent.active
    refute agent.conversation_enabled
    assert agent.model_max_context_tokens == 128_000
    assert agent.advanced_options == %{"stream" => false}
    assert agent.credential_id
    refute Jido.AgentServer.whereis(Jido.registry_name(Zaq.Agent.Jido), "#{agent.name}:#{scope}")
  end
end
