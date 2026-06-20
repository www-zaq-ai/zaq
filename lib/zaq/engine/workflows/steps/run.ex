defmodule Zaq.Engine.Workflows.Step.Run do
  @moduledoc """
  Ecto schema for a single step execution within a workflow run.

  One row is written per step execution. The `WorkflowRunAgent` writes a row
  with `status: :running` before executing each step (crash-safe cursor),
  then updates it to `completed` or `failed` after the action returns.

  On rehydration after a crash, the agent queries all rows for the run ordered
  by `step_index` to rebuild `previous_results` and locate the resume cursor.

  Statuses:
  - `running`      — action is executing (or was mid-flight when the node crashed)
  - `paused`       — action was in-flight when run pause was requested
  - `waiting`      — action suspended pending human approval (human-in-the-loop)
  - `completed`    — action returned `{:ok, result}`
  - `failed`       — action returned `{:error, reason}` or exceeded max retries;
                     **fails the whole run** (`finalize/2`)
  - `failed_fatal` — an *isolated* per-fork `map` failure under `:skip_and_continue`/
                     `:retry`. The item genuinely failed (recorded for visibility,
                     errors recovered by `MapCollect`) but does **not** fail the run —
                     `finalize/2` only fails on `failed`/`running`. NOTE: despite the
                     name, this is the *non*-run-failing failure; the run-failing one is
                     plain `failed`.
  - `skipped`      — condition evaluated to false; downstream nodes were not executed
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.WorkflowRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(running paused waiting completed failed failed_fatal skipped)

  @type t :: %__MODULE__{}

  schema "workflow_action_results" do
    belongs_to :workflow_run, WorkflowRun
    field :step_name, :string
    field :step_index, :integer
    field :status, :string, default: "running"
    field :input, :map
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
      :input,
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
