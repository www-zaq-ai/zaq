defmodule Zaq.Engine.Workflows.Steps.HumanInTheLoop do
  @moduledoc """
  Workflow action that suspends execution pending human or agent approval.

  When reached in a DAG, this action creates a `StepApproval` record and
  returns `{:error, {:waiting_for_human, approval_token}}`. `StepRunner`
  pattern-matches this to mark the step as `"waiting"` and return
  `{:error, :waiting_for_human}`. `WorkflowRunAgent` then transitions the run to
  `"waiting"` by inspecting step statuses in `finalize/2`.

  Approval or rejection arrives as a `:workflow` event dispatched to the engine:

      Event.new(%{action: "run.approve", run_id: id, person_id: pid, decision: %{}},
                :engine, name: :workflow)

  On approval, downstream steps receive the approval data as their input:

      %{approved: true, decision: %{...}, approved_by: "..."}

  ## Parameters

  - `message` (optional) — a human-readable description shown to the approver.

  ## Usage in workflow steps JSONB

      %{
        "type"   => "action",
        "name"   => "human_in_the_loop",
        "module" => "Zaq.Engine.Workflows.Steps.HumanInTheLoop",
        "params" => %{"message" => "Please review and approve before continuing."}
      }
  """

  use Zaq.Engine.Workflows.Action,
    name: "human_in_the_loop",
    schema: [message: [type: :string, required: false]],
    output_schema: [
      approved: [type: :boolean, required: true],
      decision: [type: :map, required: false],
      approved_by: [type: :string, required: false]
    ]

  alias Zaq.Engine.Workflows

  @impl Jido.Action
  def run(params, context) do
    run_id = Map.get(context, :run_id) || raise ArgumentError, "run_id missing from context"

    step_name =
      Map.get(context, :step_name) || raise ArgumentError, "step_name missing from context"

    approval_token = Ecto.UUID.generate()

    {:ok, _approval} =
      Workflows.create_approval(%{
        workflow_run_id: run_id,
        step_name: step_name,
        approval_token: approval_token,
        message: params[:message],
        status: "pending"
      })

    {:error, {:waiting_for_human, approval_token}}
  end
end
