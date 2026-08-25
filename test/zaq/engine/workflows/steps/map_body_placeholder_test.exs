defmodule Zaq.Engine.Workflows.Steps.MapBodyPlaceholderTest do
  @moduledoc """
  A `{{...}}` in a `map`/`Batch` body sub-step's params must be resolved before the
  sub-step's action runs, exactly as it is for a top-level node.

  `StepRunner.resolve_placeholders/3` is driven by the `__placeholder_keys__` list
  stamped onto the wrapper params by `DagBuilder.wrapper_params/5`. That function is
  the single producer of the shape: `build_action_node/5` uses it for a regular node
  and `MapNodeBuilder.build_fork_spec/4` for a fork sub-step, so a body node cannot
  drift from a top-level one. It regressed once because the fork spec built the same
  map by hand and omitted the key, leaving the action holding the raw `"{{...}}"`.

  Nothing raises — the braces are concatenated straight into the output and the run
  reports `"completed"`, which is why no existing test catches it: the only Batch
  fixture (`identify_leads_from_google_sheet.json`) has no placeholder in its body.

  Both `process` and `post_process` are covered, since both route through
  `build_fork_specs/4`.

  This was a regression. Before placeholder resolution moved into `StepRunner`,
  `Concat` resolved its own `parts` inside `run/2` against its non-reserved params
  (the deleted `lookup_fact/2` + `resolve_part/2`), so a body node behaved the same
  inside a fork as outside one.

  The run goes through `WorkflowRunAgent.execute/1` over a real `Batch` node holding
  a real `Concat` body node, so the assertion fails at the seam rather than against
  a stub.
  """
  use Zaq.DataCase, async: true

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @list_clients_module "Zaq.Engine.Workflows.Test.ListClients"
  @batch_module "Zaq.Agent.Tools.Workflow.Batch"
  @categorize_module "Zaq.Engine.Workflows.Test.CategorizeBySize"
  @concat_module "Zaq.Agent.Tools.Workflow.Concat"

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  # list_clients → batch[categorize, (greet)] — one chunk of 10, with `greet` placed
  # in whichever section is under test.
  #
  # `categorize` is always first because `Batch.detect_field/1` reads the *first*
  # `process` node's batch field to decide what the fan-out unit is delivered under —
  # putting `Concat` there would deliver the chunk as its `parts`. `greet` is the node
  # under test: its `parts` reference a sibling param, the reference form a fork can
  # resolve entirely from its own params.
  @greet_node %{
    "name" => "greet",
    "type" => "action",
    "module" => @concat_module,
    "params" => %{
      "greeting" => "Hello",
      "audience" => "clients",
      "parts" => ["{{greeting}}", " ", "{{audience}}"]
    }
  }

  defp workflow_with_greet_in(section) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "Batch Placeholder #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "list_clients",
            type: "action",
            module: @list_clients_module,
            params: %{},
            index: 0
          },
          %{
            name: "batch",
            type: "action",
            module: @batch_module,
            params:
              %{
                "batch_size" => 10,
                "strategy" => "skip_and_continue",
                "process" => [
                  %{
                    "name" => "categorize",
                    "type" => "action",
                    "module" => @categorize_module,
                    "params" => %{}
                  }
                ],
                "post_process" => []
              }
              |> Map.update!(section, &(&1 ++ [@greet_node])),
            index: 1
          }
        ],
        edges: [
          %{from: "list_clients", to: "batch", mapping: %{"items" => "clients"}}
        ]
      })

    wf
  end

  describe "a `{{...}}` inside a Batch body sub-step" do
    for section <- ["process", "post_process"] do
      test "is resolved before the body action runs (#{section})" do
        wf = workflow_with_greet_in(unquote(section))
        {:ok, run} = Workflows.create_run(wf, @source_event)

        assert {:ok, finished} = WorkflowRunAgent.execute(run)

        # The failure mode is silent: the run completes and the braces just flow
        # into the output. Asserting this first keeps the real assertion below from
        # being masked by an unrelated crash.
        assert finished.status == "completed"

        greet_run =
          finished.id
          |> Workflows.list_step_runs()
          |> Enum.find(&String.starts_with?(&1.step_name, "batch/greet"))

        assert greet_run, "expected a StepRun for the batch body node `greet`"

        assert greet_run.results["result"] == "Hello clients",
               "a body node's placeholders were not resolved — got: " <>
                 inspect(greet_run.results["result"])
      end
    end
  end
end
