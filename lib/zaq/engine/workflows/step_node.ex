defmodule Zaq.Engine.Workflows.StepNode do
  @moduledoc """
  Embedded schema for a single node in a workflow DAG.

  Stored as a JSONB array in the `nodes` column of `workflows`.
  Validated at changeset time so malformed steps are rejected before they
  reach `DagBuilder` at run time.

  Node types:
  - `"action"` / `"agent"` — requires `module`
  - `"condition"`           — `module` is optional (inline conditions omit it)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  @types ~w(action agent condition)

  embedded_schema do
    field :name, :string
    field :type, :string
    field :module, :string
    field :index, :integer
    field :params, :map, default: %{}
  end

  def types, do: @types

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:name, :type, :module, :index, :params])
    |> validate_required([:name, :type, :index])
    |> validate_inclusion(:type, @types)
    |> validate_module_required_for_action()
  end

  defp validate_module_required_for_action(changeset) do
    type = get_field(changeset, :type)
    module = get_field(changeset, :module)

    if type in ["action", "agent"] && (is_nil(module) || module == "") do
      add_error(changeset, :module, "is required for action/agent nodes")
    else
      changeset
    end
  end
end
