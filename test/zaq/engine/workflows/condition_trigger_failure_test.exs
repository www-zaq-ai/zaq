defmodule Zaq.Engine.Workflows.ConditionTriggerFailureTest do
  @moduledoc """
  End-to-end proof that a halting `Condition` node fails a trigger-bound run with a
  **human-readable** error in the run view.

  Scenario (see docs/exec-plans/active/condition-clear-error-test.md):

    - Workflow A produces `person: %{name: "John Doe", age: 24, position: "CTO"}`
      and dispatches an event. That dispatch is modelled by firing the trigger event
      directly through `TriggerNode.fire/2` — the same path the real
      `DispatchEvent`/`NodeRouter` dispatch takes into `EventRegistry`. The person
      fields ride in the event's `request`, which TriggerNode forwards as the run's
      initial fact (so a first-node `Condition` reads them at root).
    - Workflow B is trigger-bound to that event. Its first (and only) node is a
      `Condition` in `:halt` mode requiring `position == "CFO"` AND `position == "CEO"`.
    - `position` is `"CTO"`, so **both** conditions fail → the step fails and the run
      ends `failed`, with the clear sentence stored verbatim on the `StepRun`.
  """
  use Zaq.DataCase, async: false

  alias Zaq.Engine.{TriggerNode, Workflows}
  alias Zaq.Event

  @event_name "engine:person_identified"
  @condition_module "Zaq.Agent.Tools.Workflow.Condition"

  setup do
    # Workflow lifecycle events dispatch through the NodeRouter; make it a no-op.
    stub(Zaq.NodeRouterMock, :dispatch, fn %Event{} = event -> event end)
    :ok
  end

  # Workflow B: a single halting Condition node off the trigger, requiring the
  # person's `position` to equal BOTH "CFO" and "CEO" (so a "CTO" fails both).
  defp setup_workflow do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Position Gate Test #{System.unique_integer()}",
        status: "active",
        nodes: [
          %{
            name: "check_position",
            type: "action",
            module: @condition_module,
            params: %{
              "on_fail" => "halt",
              "conditions" => [
                %{"key" => "position", "op" => "eq", "value" => "CFO"},
                %{"key" => "position", "op" => "eq", "value" => "CEO"}
              ]
            },
            index: 0
          }
        ],
        edges: []
      })

    {:ok, trigger} = Workflows.create_trigger(%{event_name: @event_name, enabled: true})
    {:ok, _} = Workflows.assign_workflow_to_trigger(trigger, workflow)

    workflow
  end

  # Fires the trigger event synchronously through TriggerNode (the same function
  # EventRegistry calls on a matching dispatch), carrying the person payload as the
  # run's initial fact via `request`.
  defp fire do
    event = %Event{
      request: %{"name" => "John Doe", "age" => 24, "position" => "CTO"},
      next_hop: nil,
      name: :person_identified_test,
      trace_id: Ecto.UUID.generate(),
      assigns: %{}
    }

    TriggerNode.fire(@event_name, event)
  end

  defp latest_run(workflow), do: workflow.id |> Workflows.list_runs() |> List.first()

  defp step_runs(run), do: run.id |> Workflows.list_step_runs() |> Map.new(&{&1.step_name, &1})

  describe "halting condition off a trigger with a failing position" do
    test "marks the run failed and stores the clear, field-named error" do
      workflow = setup_workflow()

      assert :ok = fire()

      run = latest_run(workflow)
      assert run.status == "failed"

      steps = step_runs(run)
      step = steps["check_position"]
      assert step.status == "failed"

      reason = step.errors["reason"]
      # Names the field, both expected values, and the actual value — no duplicate
      # keys, no opaque `condition_failed:position,position`.
      assert reason ==
               ~s(Condition not met: position must equal "CFO" but was "CTO"; ) <>
                 ~s(position must equal "CEO" but was "CTO")

      assert reason =~ "position must equal"
      assert reason =~ ~s("CTO")
      refute reason =~ "condition_failed"
    end

    test "records the failure in the run's log_summary" do
      workflow = setup_workflow()

      :ok = fire()

      run = latest_run(workflow)
      assert run.log_summary["failed_step_count"] == 1
      assert run.log_summary["failed_steps"] == ["check_position"]
    end
  end
end
