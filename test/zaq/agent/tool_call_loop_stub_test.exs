defmodule Zaq.Agent.ToolCallLoopStubTest do
  @moduledoc """
  Phase-0 spike for the run_agent-as-tool work: proves a full
  **LLM → tool → LLM** loop round-trips through `OpenAIStub` +
  `MultiAgentOpenAIStub` SSE builders, the real ReqLLM Responses-API parser, and
  the jido_ai react strategy — using the EXISTING `arithmetic.add` tool so it is
  independent of any run_agent change. If this is green, the multi-agent stub
  harness used by the nested-agent integration tests is sound.
  """
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Executor
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.{MultiAgentOpenAIStub, OpenAIStub}

  test "agent executes a tool call and returns a final answer (full react loop)" do
    test_pid = self()

    handler = fn _conn, body ->
      sse =
        if MultiAgentOpenAIStub.tool_result?(body) do
          # 2nd turn: the tool result (result: 5) was fed back → final answer.
          MultiAgentOpenAIStub.text_sse("The sum is 5.", "gpt-4.1-mini")
        else
          # 1st turn: ask to call the `add` tool with 2 + 3.
          MultiAgentOpenAIStub.tool_call_sse("add", %{value: 2, amount: 3}, model: "gpt-4.1-mini")
        end

      send(test_pid, {:llm_turn, MultiAgentOpenAIStub.tool_result?(body)})
      {200, sse}
    end

    {child_spec, endpoint} = OpenAIStub.server(handler, test_pid)
    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Spike Cred #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Spike Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "Use tools to compute sums.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["arithmetic.add"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)

    incoming = %Incoming{content: "add 2 and 3", channel_id: "bo-test", provider: :web}
    outgoing = Executor.run(incoming, agent_id: to_string(configured_agent.id))

    assert outgoing.metadata.error == false
    assert outgoing.body =~ "The sum is 5"

    # The loop really happened: a first (tool-call) turn and a second
    # (tool-result) turn both hit the stub.
    assert_received {:llm_turn, false}
    assert_received {:llm_turn, true}
  end
end
