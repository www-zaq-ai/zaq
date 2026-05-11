defmodule Zaq.Workflows.WorkflowRun do
  @moduledoc """
  Ecto schema for a single workflow execution.

  Created by a trigger. The workflow's `steps` and `settings` are snapshotted
  into this row at creation time — the `WorkflowAgent` never re-reads the live
  `Workflow` row. Edits to a workflow cannot affect a run already in progress.

  `source_event` stores the triggering `%Zaq.Event{}` as JSONB via a custom
  Ecto type. It is loaded back as a plain map; callers can use `Zaq.Event`
  fields directly via map access.

  Statuses:
  - `pending`   — created, agent not yet started
  - `running`   — agent actively executing steps
  - `waiting`   — paused at a human-in-the-loop step
  - `completed` — all steps finished successfully
  - `failed`    — a step exceeded retries or a fatal error occurred
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Workflows.Workflow

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running waiting completed failed)

  @type t :: %__MODULE__{}

  schema "workflow_runs" do
    belongs_to :workflow, Workflow
    field :steps_snapshot, :map
    field :settings_snapshot, :map, default: %{}
    field :status, :string, default: "pending"
    field :source_event, :map
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

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
      :finished_at
    ])
    |> validate_required([:workflow_id, :steps_snapshot, :source_event, :status])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:workflow_id)
  end
end
