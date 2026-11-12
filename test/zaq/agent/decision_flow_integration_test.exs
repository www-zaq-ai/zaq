defmodule Zaq.Agent.DecisionFlowIntegrationTest do
  use Zaq.DataCase, async: false

  alias Zaq.Agent.Actions.EvaluateDecisions
  alias Zaq.Agent.Executor
  alias Zaq.Agent.Factory
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.System
  alias Zaq.TestSupport.{IntegrationAgent, OpenAIStub, ToolCallingLLMStub}

  test "a configured agent calls the shared Action and consumes actual alternative probabilities" do
    arguments = %{
      state: "A duplicate charge",
      questions: %{
        "team" => %{
          type: "choice",
          instructions: "Which team?",
          criteria: %{"billing" => "Payments", "support" => "Technical problems"}
        }
      }
    }

    chat =
      ToolCallingLLMStub.handler(
        routes: [
          %{match: fn _ -> true end, tool: "evaluate_decisions", arguments: fn _ -> arguments end}
        ],
        final_response: fn %{tool_result: result} ->
          "Observed decision: #{Jason.encode!(result)}"
        end
      )

    {_pid, endpoint} =
      OpenAIStub.start!(
        fn conn, body ->
          case conn.request_path do
            "/v1/systemone" ->
              assert conn.method == "POST"
              assert Jason.decode!(body)["state"] == "A duplicate charge"

              {200,
               OpenAIStub.decision_response(%{
                 "team" => %{
                   "type" => "choice",
                   "choice" => "billing",
                   "probabilities" => %{"billing" => 0.9, "support" => 0.1}
                 }
               })}

            _ ->
              request = Jason.decode!(body)

              tool =
                Enum.find(request["tools"], fn tool ->
                  (tool["name"] || get_in(tool, ["function", "name"])) == "evaluate_decisions"
                end)

              parameters = tool["parameters"] || get_in(tool, ["function", "parameters"])
              questions = parameters["properties"]["questions"]["additionalProperties"]
              assert length(questions["oneOf"]) == 3

              choice =
                Enum.find(questions["oneOf"], &(&1["properties"]["type"]["const"] == "choice"))

              assert choice["properties"]["criteria"]["additionalProperties"]["type"] == "string"
              assert "instructions" in choice["required"]
              chat.(conn, body)
          end
        end,
        self()
      )

    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{
        provider: "zaq_router",
        endpoint: endpoint,
        api_key: "decision-key"
      })

    assert {:ok, _} =
             System.save_decision_model_config(%{
               credential_id: credential.id,
               model: "typesafe/jev-1.14"
             })

    scope = "decision-flow-#{Ecto.UUID.generate()}"

    agent =
      IntegrationAgent.create!(endpoint, scope, "Classify using decisions", [
        "general.evaluate_decisions"
      ])

    incoming = %Incoming{
      content: "Please classify this ticket",
      channel_id: scope,
      provider: :web
    }

    outgoing =
      Executor.run(incoming,
        agent_id: to_string(agent.id),
        scope: scope,
        event: Zaq.Event.new(incoming, :agent, actor: %{kind: :anonymous, subject: scope})
      )

    assert_received {:llm_tool_call, "evaluate_decisions", _}
    assert_received {:llm_tool_result, "evaluate_decisions", result}

    assert result == %{
             "ok" => true,
             "result" => %{
               "decisions" => %{
                 "team" => %{
                   "type" => "choice",
                   "value" => "billing",
                   "confidence" => nil,
                   "probabilities" => %{"billing" => 0.9, "support" => 0.1}
                 }
               }
             }
           }

    refute_received {:llm_stub_error, _}
    assert outgoing.metadata.error == false
    assert outgoing.body == "Observed decision: #{Jason.encode!(result)}"
    assert_received {:openai_request, "POST", "/v1/systemone", _, _}
  end

  test "agents do not receive the decision tool implicitly" do
    agent = IntegrationAgent.create!("http://127.0.0.1:1/v1", "disabled-decision", "No tools", [])
    assert {:ok, config} = Factory.runtime_config(agent)
    refute EvaluateDecisions in config.tools
  end
end
