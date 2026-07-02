defmodule Zaq.Engine.Workflows.WorkflowRun do
  @moduledoc """
  Ecto schema for a single workflow execution.

  Created by a trigger. The workflow's `steps` and `settings` are snapshotted
  into this row at creation time — the `WorkflowRunAgent` never re-reads the live
  `Workflow` row. Edits to a workflow cannot affect a run already in progress.

  `source_event` stores the triggering `%Zaq.Event{}` as JSONB via
  `Zaq.Types.WorkflowEvent`. It is loaded back as a `%Zaq.Event{}` struct —
  callers access fields directly (e.g. `run.source_event.trace_id`).

  Statuses:
  - `pending`      — created, agent not yet started
  - `running`      — agent actively executing steps
  - `waiting`      — a `HumanInTheLoop` step suspended execution pending approval
  - `paused`       — externally paused; resume via `Workflows.resume_run/2`
  - `completed`    — all steps finished successfully
  - `failed`       — a step exceeded retries or a fatal error occurred
  - `cancelled`    — explicitly cancelled before completion
  - `interrupted`  — node restarted while run was executing; use
                     `Workflows.interrupt_run/1` to mark it and surface it in the BO
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.Workflow

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running waiting paused completed failed cancelled interrupted)

  @type t :: %__MODULE__{}

  schema "workflow_runs" do
    belongs_to :workflow, Workflow
    field :steps_snapshot, :map
    field :settings_snapshot, :map, default: %{}
    field :status, :string, default: "pending"
    field :source_event, Zaq.Types.WorkflowEvent
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :log_summary, :map

    # Assembled `Runic.Workflow` for this run, prepared in-memory by
    # `Workflows.create_run/4`. Holds closures/function references, so it is
    # never persisted — the durable artifact remains `steps_snapshot`.
    field :prepared_dag, :any, virtual: true

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workflow_id,
      :steps_snapshot,
      :settings_snapshot,
      :status,
      :source_event,
      :started_at,
      :finished_at,
      :log_summary
    ])
    |> validate_required([:workflow_id, :steps_snapshot, :source_event, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:workflow_id)
  end
end
