defmodule Zaq.Engine.Workflows.InputContractOptionalFieldAgreementTest do
  @moduledoc """
  Optional means the payload *may omit* the field, not that any value will do.

  `OptionalTypedParamAction` declares `count` (required integer) and `label`
  (optional string) — the shape of the question this file answers: a workflow that needs
  `count` but also lets an author wire `label`. Wiring `label` does not make the
  payload owe it, so it is an *optional* input: omit it and the run still completes.
  But `StepRunner` validates every declared field it is handed a value for, required
  or not, so a wrong-kinded `label` fails the run. The contract has to say so
  *before* the run, or a `valid?: true` verdict is a false clearance. Optional
  forgives absence, not the wrong kind of value — both halves are asserted here.

  Nothing here is stubbed: the real `create_workflow` → `create_run` →
  `DagBuilder` → `WorkflowRunAgent` → `StepRunner` path executes, and the
  assertions read the step run rows it wrote.
  """
  use Zaq.DataCase, async: true

  import Zaq.InputContractHelpers

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.InputContract
  alias Zaq.Engine.Workflows.Test.OptionalTypedParamAction
  alias Zaq.Engine.Workflows.WorkflowRunAgent

  @module to_string(OptionalTypedParamAction)

  setup do
    stub(Zaq.NodeRouterMock, :dispatch, fn %Zaq.Event{} = event -> event end)
    :ok
  end

  # One entry node whose params wire both fields out of the trigger payload, the
  # way an author writes them in the builder.
  defp wired_workflow do
    {:ok, workflow} =
      Workflows.create_workflow(%{
        name: "Optional field #{System.unique_integer([:positive])}",
        status: "active",
        nodes: [
          %{
            name: "typed",
            type: "action",
            module: @module,
            index: 0,
            params: %{"count" => "{{start.count}}", "label" => "{{start.label}}"}
          }
        ],
        edges: []
      })

    workflow
  end

  defp run_with(workflow, payload) do
    {:ok, run} =
      Workflows.create_run(workflow, %{
        "request" => %{},
        "assigns" => %{"trigger_type" => "manual", "input" => payload, "machine" => true},
        "trace_id" => Ecto.UUID.generate()
      })

    {:ok, finished} = WorkflowRunAgent.execute(run)
    {finished, Workflows.list_step_runs(finished.id)}
  end

  defp validation_failures(step_runs) do
    for s <- step_runs,
        s.status == "failed",
        reason = s.errors["reason"],
        is_binary(reason),
        String.contains?(reason, "Invalid parameters"),
        do: {s.step_name, reason}
  end

  describe "an optional field the graph wires" do
    test "is an optional input, and carries its declared type all the same" do
      workflow = wired_workflow()

      assert InputContract.required_inputs(workflow) == ["count"]
      assert InputContract.optional_inputs(workflow) == ["label"]
      assert InputContract.input_types(workflow)["label"] != "any"
    end

    test "may be omitted — the contract clears it and the run completes" do
      workflow = wired_workflow()
      payload = %{"count" => 3}

      assert %{valid?: true, errors: []} =
               InputContract.contract(workflow, payload)

      {_run, step_runs} = run_with(workflow, payload)

      assert validation_failures(step_runs) == []
      assert [%{status: "completed", step_name: "typed"}] = step_runs
    end

    test "a correctly-typed payload is valid, and the run completes" do
      workflow = wired_workflow()
      payload = %{"count" => 3, "label" => "ok"}

      assert %{valid?: true, errors: []} = InputContract.contract(workflow, payload)

      {_run, step_runs} = run_with(workflow, payload)

      assert validation_failures(step_runs) == []
      assert [%{status: "completed", step_name: "typed"}] = step_runs
    end

    test "a wrong-typed optional value is invalid before the run, and refused by it" do
      workflow = wired_workflow()
      payload = %{"count" => 3, "label" => 42}

      contract = InputContract.contract(workflow, payload)

      assert contract.valid? == false
      assert missing(contract) == []

      assert [%{path: ["label"], code: :invalid_type, message: "expected string, got integer"}] =
               contract.errors

      {_run, step_runs} = run_with(workflow, payload)

      assert [{"typed", reason}] = validation_failures(step_runs)
      assert reason =~ "label: expected string, got integer"
    end

    # The forbidden state, stated as the invariant rather than as one example:
    # the contract may never clear a payload the run then refuses.
    test "the contract never clears a value the run refuses" do
      workflow = wired_workflow()

      for label <- ["ok", 42, 4.2, true, ["a"], %{"a" => 1}] do
        payload = %{"count" => 3, "label" => label}
        contract = InputContract.contract(workflow, payload)
        {_run, step_runs} = run_with(workflow, payload)

        if contract.valid? do
          assert validation_failures(step_runs) == [],
                 "contract said valid but the run refused label=#{inspect(label)}"
        end
      end
    end
  end
end
