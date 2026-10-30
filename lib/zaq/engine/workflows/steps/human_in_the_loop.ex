defmodule Zaq.Engine.Workflows.Steps.HumanInTheLoop do
  @moduledoc """
  Workflow action that suspends execution pending human or agent approval.

  Creates or reuses the durable pending `StepApproval` for this exact run/step
  and returns an empty, validated business payload with typed `PendingApproval`
  success metadata. StepRunner records waiting and forwards that control to the
  sequential driver, which stops before applying the result or running siblings.
  No process waits for a human. Existing authorized approval/resume rebuilds the
  graph and replays the decision data from the completed cursor.

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
    output_schema: Zoi.object(%{})

  alias Zaq.Engine.Workflows
  alias Zaq.Engine.Workflows.PendingApproval

  @impl Jido.Action
  def run(params, context) do
    run_id = Map.get(context, :run_id) || raise ArgumentError, "run_id missing from context"

    step_name =
      Map.get(context, :step_name) || raise ArgumentError, "step_name missing from context"

    with {:ok, approval} <-
           Workflows.ensure_pending_approval(%{
             workflow_run_id: run_id,
             step_name: step_name,
             message: params[:message],
             status: "pending"
           }) do
      {:ok, %{},
       workflow_control: %PendingApproval{
         run_id: run_id,
         step_name: step_name,
         approval_token: approval.approval_token
       }}
    end
  end
end
