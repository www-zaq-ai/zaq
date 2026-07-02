defmodule Zaq.Engine.Workflows.StepApproval do
  @moduledoc """
  Ecto schema for a human-in-the-loop approval record.

  Created when a `HumanInTheLoop` step is reached during workflow execution.
  The `approval_token` is a UUID used to look up and act on the approval
  from any producer (BO, channel adapter, AI agent) via the `:workflow` event.

  Statuses:
  - `pending`  — awaiting a human or agent decision
  - `approved` — run was approved and has been resumed
  - `rejected` — run was rejected and has been failed

  One approval record exists per `(workflow_run_id, step_name)` pair.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.WorkflowRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending approved rejected)

  @type t :: %__MODULE__{}

  schema "step_approvals" do
    belongs_to :workflow_run, WorkflowRun
    field :step_name, :string
    field :approval_token, :string
    field :message, :string
    field :status, :string, default: "pending"
    field :decision, :map
    field :approved_by, :string
    field :approved_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [
      :workflow_run_id,
      :step_name,
      :approval_token,
      :message,
      :status,
      :decision,
      :approved_by,
      :approved_at
    ])
    |> validate_required([:workflow_run_id, :step_name, :approval_token, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:workflow_run_id)
    |> unique_constraint(:approval_token)
    |> unique_constraint(:step_name, name: :step_approvals_workflow_run_id_step_name_index)
  end
end
