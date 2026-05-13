defmodule Zaq.Engine.Workflows.WorkflowAgentTest do
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowAgent

  @ok_module "Zaq.Engine.Workflows.Test.OkAction"
  @error_module "Zaq.Engine.Workflows.Test.ErrorAction"

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  defp single_node_steps(module) do
    %{
      "nodes" => [
        %{"name" => "step", "type" => "action", "module" => module, "params" => %{}, "index" => 0}
      ],
      "edges" => []
    }
  end

  defp create_run(module \\ @ok_module) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "WA Test #{System.unique_integer()}",
        status: "active",
        steps: single_node_steps(module)
      })

    {:ok, run} = Workflows.create_run(wf, @source_event)
    run
  end

  describe "execute/1 — happy path" do
    test "transitions WorkflowRun to completed" do
      run = create_run()

      assert {:ok, updated} = WorkflowAgent.execute(run)
      assert updated.status == "completed"
      assert updated.started_at != nil
      assert updated.finished_at != nil
    end

    test "writes a completed ActionResult row for the step" do
      run = create_run()

      {:ok, updated} = WorkflowAgent.execute(run)
      results = Workflows.list_step_runs(updated.id)

      assert length(results) == 1
      [ar] = results
      assert ar.step_name == "step"
      assert ar.status == "completed"
      assert ar.finished_at != nil
    end

    test "run starts at pending and transitions through running to completed" do
      run = create_run()
      assert run.status == "pending"

      {:ok, updated} = WorkflowAgent.execute(run)
      assert updated.status == "completed"
    end
  end

  describe "execute/1 — step failure" do
    test "transitions WorkflowRun to failed when a step errors" do
      run = create_run(@error_module)

      assert {:ok, updated} = WorkflowAgent.execute(run)
      assert updated.status == "failed"
      assert updated.finished_at != nil
    end

    test "ActionResult row for failing step is marked failed" do
      run = create_run(@error_module)

      {:ok, updated} = WorkflowAgent.execute(run)
      [ar] = Workflows.list_step_runs(updated.id)

      assert ar.status == "failed"
      assert ar.errors["reason"] =~ "test_failure"
    end
  end

  describe "execute/1 — DagBuilder failure" do
    test "transitions WorkflowRun to failed when steps snapshot is invalid" do
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WA Bad Steps #{System.unique_integer()}",
          status: "draft",
          steps: %{"nodes" => [], "edges" => []}
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)

      assert {:error, _} = WorkflowAgent.execute(run)

      reloaded = Workflows.get_run!(run.id)
      assert reloaded.status == "failed"
    end
  end

  describe "execute/1 — multi-step workflow" do
    test "writes one ActionResult per action step" do
      steps = %{
        "nodes" => [
          %{
            "name" => "first",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 0
          },
          %{
            "name" => "second",
            "type" => "action",
            "module" => @ok_module,
            "params" => %{},
            "index" => 1
          }
        ],
        "edges" => [%{"from" => "first", "to" => "second"}]
      }

      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "WA Multi #{System.unique_integer()}",
          status: "active",
          steps: steps
        })

      {:ok, run} = Workflows.create_run(wf, @source_event)

      {:ok, updated} = WorkflowAgent.execute(run)
      assert updated.status == "completed"

      results = Workflows.list_step_runs(updated.id)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == "completed"))
    end
  end
end
