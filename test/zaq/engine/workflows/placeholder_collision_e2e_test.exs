defmodule Zaq.Engine.Workflows.PlaceholderCollisionE2ETest do
  @moduledoc """
  End-to-end coverage for the two claims argued on PR #696 finding 2, run through
  the real seam — `WorkflowRunAgent` → `StepRunner` → `EdgeStep` → `Placeholders`,
  nothing stubbed.

  1. **Cascade scoping holds.** A trigger payload and an upstream node that both
     emit `x` stay independently reachable as `start.x` and `a.x`. Only the
     unqualified root is last-writer-wins.
  2. **A runtime value landing on a placeholder-bearing key is re-resolved.**
     `__placeholder_params__` records the value the author wrote for each
     placeholder-bearing key, so a value an edge `mapping` later delivers onto that
     same key is recognised as runtime data and reaches the action verbatim —
     rather than having `{{...}}` a lead typed substituted for it.
  """
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @echo "Zaq.Engine.Workflows.Test.EchoResolved"
  @braced "Zaq.Engine.Workflows.Test.EmitBracedBody"
  @nested_x "Zaq.Engine.Workflows.Test.EmitNestedX"

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp run_workflow(nodes, edges, payload) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "PlaceholderCollision #{System.unique_integer()}",
        status: "active",
        nodes: nodes,
        edges: edges
      })

    {:ok, run} =
      Workflows.create_run(wf, %{
        "request" => nil,
        "assigns" => %{"trigger_type" => "manual", "input" => payload},
        "trace_id" => Ecto.UUID.generate()
      })

    {:ok, finished} = WorkflowRunAgent.execute(run)
    {finished, Workflows.list_step_runs(run.id)}
  end

  defp seen(step_runs, step_name, key) do
    step_runs
    |> Enum.find(&(&1.step_name == step_name))
    |> Map.fetch!(:results)
    |> Zaq.MapUtils.fetch_either(:seen, "seen")
    |> Zaq.MapUtils.fetch_either(key, Atom.to_string(key))
  end

  describe "cascade scoping when an upstream node shadows a trigger key" do
    setup do
      nodes = [
        %{name: "a", type: "action", module: @nested_x, params: %{}, index: 0},
        %{
          name: "probe",
          type: "action",
          module: @echo,
          params: %{
            "from_start" => "{{start.x.b}}",
            "from_node" => "{{a.x.b}}",
            "unqualified" => "{{x.b}}"
          },
          index: 1
        }
      ]

      {finished, step_runs} =
        run_workflow(nodes, [%{from: "a", to: "probe"}], %{"x" => %{"a" => 1, "b" => 2}})

      assert finished.status == "completed"
      %{step_runs: step_runs}
    end

    test "start.x and a.x do not collide — both stay reachable", %{step_runs: step_runs} do
      assert seen(step_runs, "probe", :from_start) == 2
      assert seen(step_runs, "probe", :from_node) == 3
    end

    test "the unqualified root is last-writer-wins", %{step_runs: step_runs} do
      assert seen(step_runs, "probe", :unqualified) == 3
    end
  end

  describe "a mapping writing onto a key whose static param held a placeholder" do
    test "the runtime value reaches the action verbatim, not placeholder-resolved" do
      nodes = [
        %{name: "lead", type: "action", module: @braced, params: %{}, index: 0},
        %{
          name: "consumer",
          type: "action",
          module: @echo,
          params: %{"text" => "{{start.secret}}"},
          index: 1
        }
      ]

      edges = [%{from: "lead", to: "consumer", mapping: %{"text" => "lead.body"}}]

      {finished, step_runs} = run_workflow(nodes, edges, %{"secret" => "hunter2"})

      assert finished.status == "completed"

      assert seen(step_runs, "consumer", :text) == "lead wrote {{start.secret}} verbatim"
    end

    test "a static placeholder with no colliding mapping still resolves" do
      nodes = [
        %{name: "lead", type: "action", module: @braced, params: %{}, index: 0},
        %{
          name: "consumer",
          type: "action",
          module: @echo,
          params: %{"text" => "{{start.secret}}"},
          index: 1
        }
      ]

      {finished, step_runs} =
        run_workflow(nodes, [%{from: "lead", to: "consumer"}], %{
          "secret" => "hunter2"
        })

      assert finished.status == "completed"
      assert seen(step_runs, "consumer", :text) == "hunter2"
    end
  end
end
