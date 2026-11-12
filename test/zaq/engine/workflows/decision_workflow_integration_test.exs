defmodule Zaq.Engine.Workflows.DecisionWorkflowIntegrationTest do
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRunAgent
  alias Zaq.System
  alias Zaq.TestSupport.OpenAIStub

  @questions %{
    "refund" => %{"type" => "boolean", "instructions" => "Refund?"},
    "team" => %{
      "type" => "choice",
      "instructions" => "Team?",
      "criteria" => %{"billing" => "Payments", "support" => "Other issues"}
    }
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn
      %Zaq.Event{name: :workflow, request: %{action: action}} = event
      when action in [
             "workflow.created",
             "run.started",
             "run.completed",
             "run.failed",
             "run.incomplete"
           ] ->
        event

      %Zaq.Event{request: {:broadcast, topic, {kind, _}}, opts: [action: :broadcast]} = event
      when kind in [:run_created, :run_started, :run_updated, :run_finished, :step_updated] ->
        assert String.starts_with?(topic, ["workflow:", "workflow_run:"])
        event
    end)

    {_pid, endpoint} =
      OpenAIStub.start!(
        fn conn, body ->
          assert conn.request_path == "/v1/systemone"

          assert Plug.Conn.get_req_header(conn, "authorization") == [
                   "Bearer workflow-decision-key"
                 ]

          state = Jason.decode!(body)["state"]
          probability = if state == "first", do: 0.9, else: 0.1

          {200,
           OpenAIStub.decision_response(%{
             "refund" => %{"type" => "noul", "noul" => probability},
             "team" => %{
               "type" => "choice",
               "choice" => "billing",
               "probabilities" => %{"billing" => 0.9, "support" => 0.1}
             }
           })}
        end,
        self()
      )

    credential =
      Zaq.SystemConfigFixtures.ai_credential_fixture(%{
        provider: "zaq_router",
        endpoint: endpoint,
        api_key: "workflow-decision-key"
      })

    assert {:ok, _} =
             System.save_decision_model_config(%{
               credential_id: credential.id,
               model: "typesafe/jev-1.14"
             })

    :ok
  end

  test "saved workflow maps decisions and branches using the first of two decision steps" do
    nodes = [
      decision_node("classify", "first", 0),
      decision_node("recheck", "second", 1),
      encode_node("accepted", 2),
      encode_node("denied", 3)
    ]

    edges = [
      %{from: "classify", to: "recheck"},
      %{
        from: "recheck",
        to: "accepted",
        condition: %{"field" => "classify.decisions.refund.value", "op" => "eq", "value" => true},
        mapping: %{"data" => "classify.decisions.team.probabilities"}
      },
      %{
        from: "recheck",
        to: "denied",
        condition: %{"field" => "classify.decisions.refund.value", "op" => "eq", "value" => false},
        mapping: %{"data" => "classify.decisions.team.value"}
      }
    ]

    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Decision #{Ecto.UUID.generate()}",
        status: "active",
        nodes: nodes,
        edges: edges
      })

    workflow = Workflows.get_workflow!(workflow.id)

    source = %{
      "request" => nil,
      "assigns" => %{"trigger_type" => "manual"},
      "trace_id" => Ecto.UUID.generate()
    }

    {:ok, run} = Workflows.create_run(workflow, source)
    assert {:ok, finished} = WorkflowRunAgent.execute(run)
    assert finished.status == "completed"
    steps = Workflows.list_step_runs(run.id)
    first = Enum.find(steps, &(&1.step_name == "classify"))
    second = Enum.find(steps, &(&1.step_name == "recheck"))
    accepted = Enum.find(steps, &(&1.step_name == "accepted"))
    assert first.status == "completed"
    assert first.results["decisions"]["refund"]["value"] == true
    assert second.results["decisions"]["refund"]["value"] == false
    assert accepted.status == "completed"
    assert Jason.decode!(accepted.results["encoded"]) == %{"billing" => 0.9, "support" => 0.1}
    refute Enum.any?(steps, &(&1.step_name == "denied" and &1.status == "completed"))
  end

  defp decision_node(name, state, index) do
    %{
      name: name,
      type: "action",
      module: "Zaq.Agent.Actions.EvaluateDecisions",
      params: %{"state" => state, "questions" => @questions},
      index: index
    }
  end

  defp encode_node(name, index) do
    %{
      name: name,
      type: "action",
      module: "Zaq.Agent.Tools.General.EncodeJson",
      params: %{},
      index: index
    }
  end
end
