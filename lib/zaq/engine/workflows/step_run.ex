defmodule Zaq.Engine.Workflows.StepRun do
  @moduledoc """
  Ecto schema for a single step execution within a workflow run.

  One row is written per step execution. The `WorkflowAgent` writes a row
  with `status: :running` before executing each step (crash-safe cursor),
  then updates it to `completed` or `failed` after the action returns.

  On rehydration after a crash, the agent queries all rows for the run ordered
  by `step_index` to rebuild `previous_results` and locate the resume cursor.

  Statuses:
  - `running`   — action is executing (or was mid-flight when the node crashed)
  - `completed` — action returned `{:ok, result}`
  - `failed`    — action returned `{:error, reason}` or exceeded max retries
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.WorkflowRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(running completed failed)

  @type t :: %__MODULE__{}

  schema "workflow_action_results" do
    belongs_to :workflow_run, WorkflowRun
    field :step_name, :string
    field :step_index, :integer
    field :status, :string, default: "running"
    field :results, :map
    field :errors, :map
    field :logs, {:array, :map}, default: []
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(step_run, attrs) do
    step_run
    |> cast(attrs, [
      :workflow_run_id,
      :step_name,
      :step_index,
      :status,
      :results,
      :errors,
      :logs,
      :started_at,
      :finished_at
    ])
    |> validate_required([:workflow_run_id, :step_name, :step_index, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:workflow_run_id)
  end
end
