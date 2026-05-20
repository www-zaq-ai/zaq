defmodule Zaq.Engine.Workflows.EdgeRoutingTest do
  @moduledoc """
  Step 6 — End-to-end integration test for the user's exact conditional edge + mapping
  scenario, running through real WorkflowAgent.execute/2 → DagBuilder → Runic →
  ActionWrapper → StepRun rows.

  Scenario (verbatim from requirement):
    A → B → C  condition {gender==male}  mapping {person_name←name}  → D
         B → F  condition {gender==female} mapping {first_name←name}
  """
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowAgent

  @noop_module "Zaq.Engine.Workflows.Test.Noop"
  @emit_person_module "Zaq.Engine.Workflows.Test.EmitPerson"
  @require_person_name_module "Zaq.Engine.Workflows.Test.RequirePersonName"
  @require_first_name_module "Zaq.Engine.Workflows.Test.RequireFirstName"

  defp scenario_nodes do
    [
      %{name: "B", type: "action", module: @emit_person_module, params: %{}, index: 0},
      %{name: "C", type: "action", module: @require_person_name_module, params: %{}, index: 1},
      %{name: "D", type: "action", module: @noop_module, params: %{}, index: 2},
      %{name: "F", type: "action", module: @require_first_name_module, params: %{}, index: 1}
    ]
  end

  defp scenario_edges do
    [
      %{
        from: "B",
        to: "C",
        condition: %{field: "gender", op: :eq, value: "male"},
        mapping: %{"person_name" => "name"}
      },
      %{from: "C", to: "D"},
      %{
        from: "B",
        to: "F",
        condition: %{field: "gender", op: :eq, value: "female"},
        mapping: %{"first_name" => "name"}
      }
    ]
  end

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => "test-trace-id"
  }

  defp create_run(gender) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Edge Routing Test #{System.unique_integer()}",
        status: "active",
        nodes: scenario_nodes(),
        edges: scenario_edges()
      })

    source_event =
      Map.put(@source_event, "assigns", %{
        "trigger_type" => "manual",
        "input" => %{"gender" => gender}
      })

    {:ok, run} = Workflows.create_run(wf, source_event)
    run
  end

  describe "gender = male — C branch taken, F pruned" do
    test "run completes with status 'completed'" do
      run = create_run("male")
      assert {:ok, finished} = WorkflowAgent.execute(run)
      assert finished.status == "completed"
    end

    test "B, C, D have 'completed' StepRuns" do
      run = create_run("male")
      {:ok, _finished} = WorkflowAgent.execute(run)
      step_runs = Workflows.list_step_runs(run.id)
      by_name = Map.new(step_runs, &{&1.step_name, &1})

      assert by_name["B"].status == "completed"
      assert by_name["C"].status == "completed"
      assert by_name["D"].status == "completed"
    end

    test "F has no StepRun (pruned, ActionWrapper never called)" do
      run = create_run("male")
      {:ok, _finished} = WorkflowAgent.execute(run)
      step_runs = Workflows.list_step_runs(run.id)
      names = Enum.map(step_runs, & &1.step_name)

      refute "F" in names
    end

    test "C received person_name (mapping correctness)" do
      run = create_run("male")
      {:ok, _finished} = WorkflowAgent.execute(run)
      step_runs = Workflows.list_step_runs(run.id)
      c_run = Enum.find(step_runs, &(&1.step_name == "C"))

      assert c_run, "C StepRun must exist"
      assert c_run.results["c_ran"] == true
      assert c_run.results["person_name"] == "Sam"
    end
  end

  describe "gender = female — F branch taken, C pruned" do
    test "run completes with status 'completed'" do
      run = create_run("female")
      assert {:ok, finished} = WorkflowAgent.execute(run)
      assert finished.status == "completed"
    end

    test "B, F have 'completed' StepRuns" do
      run = create_run("female")
      {:ok, _finished} = WorkflowAgent.execute(run)
      step_runs = Workflows.list_step_runs(run.id)
      by_name = Map.new(step_runs, &{&1.step_name, &1})

      assert by_name["B"].status == "completed"
      assert by_name["F"].status == "completed"
    end

    test "C and D have no StepRuns (pruned)" do
      run = create_run("female")
      {:ok, _finished} = WorkflowAgent.execute(run)
      step_runs = Workflows.list_step_runs(run.id)
      names = Enum.map(step_runs, & &1.step_name)

      refute "C" in names
      refute "D" in names
    end

    test "F received first_name (mapping correctness)" do
      run = create_run("female")
      {:ok, _finished} = WorkflowAgent.execute(run)
      step_runs = Workflows.list_step_runs(run.id)
      f_run = Enum.find(step_runs, &(&1.step_name == "F"))

      assert f_run, "F StepRun must exist"
      assert f_run.results["f_ran"] == true
      assert f_run.results["first_name"] == "Sam"
    end
  end

  describe "gender = other — neither branch taken" do
    test "run completes with status 'completed' (pruned branches never fail the run)" do
      run = create_run("other")
      assert {:ok, finished} = WorkflowAgent.execute(run)
      assert finished.status == "completed"
    end

    test "only B has a StepRun" do
      run = create_run("other")
      {:ok, _finished} = WorkflowAgent.execute(run)
      step_runs = Workflows.list_step_runs(run.id)
      names = Enum.map(step_runs, & &1.step_name) |> Enum.sort()

      assert "B" in names
      refute "C" in names
      refute "D" in names
      refute "F" in names
    end
  end

  describe "mapping isolation" do
    test "C never receives the raw :name key from B's output" do
      # RequirePersonName.run/2 raises if it receives :name — so test passing proves isolation.
      run = create_run("male")
      assert {:ok, finished} = WorkflowAgent.execute(run)
      assert finished.status == "completed"
    end

    test "F never receives the raw :name key from B's output" do
      run = create_run("female")
      assert {:ok, finished} = WorkflowAgent.execute(run)
      assert finished.status == "completed"
    end
  end
end
