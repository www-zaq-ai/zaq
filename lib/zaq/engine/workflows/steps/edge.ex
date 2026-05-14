defmodule Zaq.Engine.Workflows.Step.Edge do
  @moduledoc """
  Embedded schema for a directed edge between two nodes in a workflow DAG.

  Stored as a JSONB array in the `edges` column of `workflows`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :from, :string
    field :to, :string
  end

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:from, :to])
    |> validate_required([:from, :to])
  end
end
