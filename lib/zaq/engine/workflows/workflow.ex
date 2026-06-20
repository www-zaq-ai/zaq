defmodule Zaq.Engine.Workflows.Workflow do
  @moduledoc """
  Ecto schema for a workflow definition.

  A workflow is a named, versioned DAG of steps. Once a run is created,
  the steps and settings are snapshotted into `WorkflowRun` — edits to
  a workflow never affect in-progress runs.

  Steps are stored as two typed embedded arrays (`nodes` and `edges`),
  validated at changeset time via `StepNode` and `StepEdge` embedded schemas.

  Statuses:
  - `draft`    — being built, not triggerable
  - `active`   — triggers enabled, runs can be created
  - `archived` — soft-deleted, no new runs
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.Step.Edge, as: StepEdge
  alias Zaq.Engine.Workflows.Step.Node, as: StepNode

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft active archived)

  @type t :: %__MODULE__{}

  schema "workflows" do
    field :name, :string
    field :description, :string
    field :status, :string, default: "draft"
    field :settings, :map, default: %{}

    embeds_many :nodes, StepNode, on_replace: :delete
    embeds_many :edges, StepEdge, on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:name, :description, :status, :settings])
    |> cast_embed(:nodes, with: &StepNode.changeset/2)
    |> cast_embed(:edges, with: &StepEdge.changeset/2)
    |> validate_required([:name, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_active_has_nodes()

    # Status transition enforcement (draft→active, active→archived,
    # archived→active; reverting to draft disallowed) is not yet implemented.
  end

  # Active workflows must have at least one node — draft/archived may be empty.
  defp validate_active_has_nodes(changeset) do
    if get_field(changeset, :status) == "active" do
      nodes = get_field(changeset, :nodes) || []

      if nodes == [] do
        add_error(changeset, :nodes, "must have at least one node for an active workflow")
      else
        changeset
      end
    else
      changeset
    end
  end
end
