defmodule Zaq.Engine.Workflows.Steps.IterateTest do
  use Zaq.DataCase, async: true
  use ExUnitProperties

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  defmodule Record do
    @moduledoc false
    use Zaq.Engine.Workflows.Action,
      name: "test_iterate_record",
      schema: Zoi.object(%{value: Zoi.any(), phase: Zoi.string() |> Zoi.optional()}),
      output_schema: Zoi.object(%{value: Zoi.any()})

    @impl true
    def run(params, _context) do
      send(self(), {:iteration, Map.get(params, :phase, "body"), params.value})
      if params.value == "fail", do: {:error, :test_failure}, else: {:ok, %{value: params.value}}
    end
  end

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  property "each item completes its whole pipeline in input order, including duplicates" do
    check all(items <- list_of(integer(), max_length: 12), max_runs: 20) do
      run = execute(items)
      assert run.status == "completed"
      assert observations() == Enum.flat_map(items, &[{"body", &1}, {"tail", &1}])
      assert aggregate(run).results["count"] == length(items)
    end
  end

  test "skip_and_continue isolates a failed item and preserves subsequent order" do
    run = execute([1, "fail", 3])
    assert run.status == "completed"

    assert observations() == [
             {"body", 1},
             {"tail", 1},
             {"body", "fail"},
             {"body", 3},
             {"tail", 3}
           ]

    assert aggregate(run).results["count"] == 3
    assert length(aggregate(run).results["errors"]) == 1
  end

  test "fail_workflow stops before later items and collection" do
    run = execute([1, "fail", 3], "fail_workflow")
    assert run.status == "failed"
    assert observations() == [{"body", 1}, {"tail", 1}, {"body", "fail"}]
    refute aggregate(run)
  end

  test "resume reuses completed steps without repeating effects" do
    run = execute([1, 2, 3])
    assert length(observations()) == 6
    {:ok, paused} = Workflows.update_run(run, %{status: "paused"})
    {:ok, resumed} = Workflows.resume_run(paused)
    assert resumed.status == "completed"
    assert observations() == []
    assert aggregate(resumed).results["count"] == 3
  end

  test "local outputs and parent cascade are available inside and after iteration" do
    run = execute([8, 9])
    steps = Workflows.list_step_runs(run.id)
    assert Enum.find(steps, &(&1.step_name == "after")).results["captured"] == [8, 9]
    assert Enum.find(steps, &(&1.step_name == "loop/tail[1]")).results["value"] == 9
  end

  defp execute(items, strategy \\ "skip_and_continue") do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Iterate #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [
          %{
            name: "source",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.CaptureValue",
            params: %{"value" => items},
            index: 0
          },
          %{
            name: "loop",
            type: "action",
            module: "Zaq.Agent.Tools.Workflow.Iterate",
            index: 1,
            params: %{
              "strategy" => strategy,
              "process" => [body("body", %{})],
              "post_process" => [body("tail", %{"value" => "body.value"})]
            }
          },
          %{
            name: "after",
            type: "action",
            module: "Zaq.Engine.Workflows.Test.CaptureValue",
            params: %{},
            index: 2
          }
        ],
        edges: [
          %{from: "source", to: "loop", mapping: %{"items" => "source.captured"}},
          %{from: "loop", to: "after", mapping: %{"value" => "source.captured"}}
        ]
      })

    {:ok, run} =
      Workflows.create_run(workflow, %{"assigns" => %{}, "trace_id" => Ecto.UUID.generate()})

    {:ok, finished} = WorkflowRunAgent.execute(run)
    finished
  end

  defp body(name, mapping) do
    %{
      "name" => name,
      "type" => "action",
      "module" => inspect(Record),
      "params" => %{"phase" => name},
      "mapping" => mapping
    }
  end

  defp aggregate(run), do: Enum.find(Workflows.list_step_runs(run.id), &(&1.step_name == "loop"))

  defp observations do
    receive do
      {:iteration, phase, value} -> [{phase, value} | observations()]
    after
      0 -> []
    end
  end
end
