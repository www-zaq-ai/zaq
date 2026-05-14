defmodule Zaq.Engine.Workflows.TriggerWorkflow do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.{Trigger, Workflow}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "trigger_workflows" do
    belongs_to :trigger, Trigger
    belongs_to :workflow, Workflow
    field :position, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(tw, attrs) do
    tw
    |> cast(attrs, [:trigger_id, :workflow_id, :position])
    |> validate_required([:trigger_id, :workflow_id])
    |> foreign_key_constraint(:trigger_id)
    |> foreign_key_constraint(:workflow_id)
    |> unique_constraint([:trigger_id, :workflow_id])
  end
end
