defmodule Zaq.Agent.ToolCallLoopStubTest do
  @moduledoc """
  Proves message-selected tool calls and actual arithmetic outputs round-trip
  through Executor, Factory, ReqLLM's Responses API and Jido.AI ReAct.
  """
  use Zaq.DataCase, async: false

  import Zaq.SystemConfigFixtures

  alias Zaq.Agent
  alias Zaq.Agent.Executor
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.TestSupport.ToolCallingLLMStub

  setup do
    routes = [
      %{
        match: &String.contains?(&1, "add 2 and 3"),
        tool: "add",
        arguments: fn _ -> %{value: 2, amount: 3} end
      },
      %{
        match: &String.contains?(&1, "subtract 3 from 10"),
        tool: "subtract",
        arguments: fn _ -> %{value: 10, amount: 3} end
      }
    ]

    {child_spec, endpoint} =
      ToolCallingLLMStub.server(routes,
        final_response: fn %{tool_result: result} ->
          "Observed result: #{Jason.encode!(result)}"
        end
      )

    start_supervised!(child_spec)

    credential =
      ai_credential_fixture(%{
        name: "Tool Loop Cred #{System.unique_integer([:positive, :monotonic])}",
        provider: "openai",
        endpoint: endpoint,
        api_key: "test-key"
      })

    {:ok, configured_agent} =
      Agent.create_agent(%{
        name: "Tool Loop Agent #{System.unique_integer([:positive])}",
        description: "",
        job: "Use tools to compute arithmetic.",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        enabled_tool_keys: ["arithmetic.add", "arithmetic.subtract"],
        conversation_enabled: false,
        active: true,
        advanced_options: %{"stream" => false}
      })

    on_exit(fn -> _ = ServerManager.stop_server(configured_agent) end)
    %{configured_agent: configured_agent}
  end

  for {message, tool, value, result} <- [
        {"Please add 2 and 3", "add", 2, 5.0},
        {"Please subtract 3 from 10", "subtract", 10, 7.0}
      ] do
    @message message
    @tool tool
    @value value
    @result result
    test "#{tool} is selected from the message and its real result reaches the LLM", %{
      configured_agent: agent
    } do
      incoming = %Incoming{content: @message, channel_id: "bo-test", provider: :web}
      outgoing = Executor.run(incoming, agent_id: to_string(agent.id))

      assert_received {:llm_tool_call, @tool, %{"value" => @value, "amount" => 3}}
      assert_received {:llm_tool_result, @tool, tool_result}
      assert tool_result === %{"ok" => true, "result" => %{"result" => @result}}
      refute_received {:llm_stub_error, _}
      assert outgoing.metadata.error == false
      assert outgoing.body == "Observed result: #{Jason.encode!(tool_result)}"

      assert_received {:openai_request, "POST", "/v1/responses", _, body}
      names = body |> Jason.decode!() |> Map.fetch!("tools") |> Enum.map(& &1["name"])
      assert "add" in names
      assert "subtract" in names
      assert_received {:openai_request, "POST", "/v1/responses", _, _}
      refute_received {:openai_request, _, _, _, _}
    end
  end
end
