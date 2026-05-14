defmodule Zaq.Engine.Workflows.TriggerChain do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.Trigger

  @primary_key false
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "trigger_chains" do
    belongs_to :trigger, Trigger
    belongs_to :downstream_trigger, Trigger
  end

  def changeset(tc, attrs) do
    tc
    |> cast(attrs, [:trigger_id, :downstream_trigger_id])
    |> validate_required([:trigger_id, :downstream_trigger_id])
    |> foreign_key_constraint(:trigger_id)
    |> foreign_key_constraint(:downstream_trigger_id)
    |> unique_constraint([:trigger_id, :downstream_trigger_id])
  end
end
