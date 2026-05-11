defmodule Zaq.Workflows.Workflow do
  @moduledoc """
  Ecto schema for a workflow definition.

  A workflow is a named, versioned DAG of steps. Once a run is created,
  the steps and settings are snapshotted into `WorkflowRun` — edits to
  a workflow never affect in-progress runs.

  Statuses:
  - `draft`    — being built, not triggerable
  - `active`   — triggers enabled, runs can be created
  - `archived` — soft-deleted, no new runs
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft active archived)

  @type t :: %__MODULE__{}

  schema "workflows" do
    field :name, :string
    field :description, :string
    field :status, :string, default: "draft"
    field :steps, :map, default: %{}
    field :settings, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:name, :description, :status, :steps, :settings])
    |> validate_required([:name, :status, :steps])
    |> validate_inclusion(:status, @statuses)
  end
end
