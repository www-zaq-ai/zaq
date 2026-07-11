defmodule Zaq.Engine.Workflows.EdgeStepStructCascadeE2ETest do
  @moduledoc """
  Step 3 (closure) of the EdgeStep struct-crash plan — end-to-end regression
  reproducing the exact failing seam from the `SendLeadsEmail` incident
  (`investigation-check-last-message-date-gate-never-ran.md`), through the real
  seam that crashed: no stubbing of `EdgeStep`, `Condition`, or `StepRunner`.

  Shape, mirroring `ensure_person.row` → `check_last_message_date`:

      a (emits a struct-bearing `row` + a nil `last_message_date`)
        --edge, mapping row/last_message_date-->
      gate (Workflow.Condition, on_fail: "continue", `last_message_date gte now-5m`)
        --edge, condition passed == false-->
      leaf

  Before the Step-1 fix, `normalize_value/1` matched the struct via `is_map/1`
  and called `Map.new(struct, fun)` — `Protocol.UndefinedError` (structs are not
  Enumerable) — the instant the `a -> gate` edge tried to normalize the mapped
  `row` value. `write_pass_trace/3` ran before `apply_mapping/2` at the time, so
  the crash left no failed row either — `gate` was silently never scheduled and
  the run finalized `incomplete` with no reason anywhere. This test pins: `gate`
  gets a `Step.Run` row, the run finalizes `"completed"`, and `leaf` runs — for
  both a top-level struct and a struct nested in a list.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @emit_module "Zaq.Engine.Workflows.Test.EmitStructRow"
  @condition_module "Zaq.Agent.Tools.Workflow.Condition"
  @noop_module "Zaq.Engine.Workflows.Test.Noop"

  @source_event %{
    "request" => nil,
    "assigns" => %{"trigger_type" => "manual"},
    "trace_id" => Ecto.UUID.generate()
  }

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  defp struct_cascade_run(shape) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "EdgeStep Struct Cascade #{shape} #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "a",
            type: "action",
            module: @emit_module,
            params: %{"shape" => shape},
            index: 0
          },
          %{
            name: "gate",
            type: "action",
            module: @condition_module,
            params: %{
              "on_fail" => "continue",
              "conditions" => [
                %{
                  "key" => "last_message_date",
                  "type" => "datetime",
                  "op" => "gte",
                  "value" => %{"from" => "now", "minutes" => -5}
                }
              ]
            },
            index: 1
          },
          %{name: "leaf", type: "action", module: @noop_module, params: %{}, index: 2}
        ],
        edges: [
          %{
            from: "a",
            to: "gate",
            mapping: %{
              "row" => "a.row",
              "last_message_date" => "a.metadata.last_message_date"
            }
          },
          %{
            from: "gate",
            to: "leaf",
            condition: %{"field" => "passed", "op" => "eq", "value" => false}
          }
        ]
      })

    {:ok, run} = Workflows.create_run(wf, @source_event)
    run
  end

  for shape <- ["top", "list"] do
    describe "struct at #{shape} — a nil last_message_date still routes through the gate" do
      test "gate has a Step.Run row (not silently skipped by a crashed mapping)" do
        run = struct_cascade_run(unquote(shape))

        {:ok, _finished} = WorkflowRunAgent.execute(run)

        step_runs = Workflows.list_step_runs(run.id)
        gate_run = Enum.find(step_runs, &(&1.step_name == "gate"))

        assert gate_run, "gate Step.Run row must exist"
        assert gate_run.status == "completed"
      end

      test "the run finalizes 'completed', not 'incomplete'" do
        run = struct_cascade_run(unquote(shape))

        assert {:ok, finished} = WorkflowRunAgent.execute(run)
        assert finished.status == "completed"
      end

      test "leaf ran" do
        run = struct_cascade_run(unquote(shape))

        {:ok, _finished} = WorkflowRunAgent.execute(run)

        step_runs = Workflows.list_step_runs(run.id)
        leaf_run = Enum.find(step_runs, &(&1.step_name == "leaf"))

        assert leaf_run, "leaf Step.Run row must exist"
        assert leaf_run.status == "completed"
      end
    end
  end
end
