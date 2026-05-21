defmodule Zaq.Engine.Workflows.Step.Edge do
  @moduledoc """
  Embedded schema for a directed edge between two nodes in a workflow DAG.

  Stored as a JSONB array in the `edges` column of `workflows`.

  ## Fields

  - `from` / `to` — node names (required).
  - `condition` — optional map with `field`, `op`, and optionally `value`. When
    present, the edge is only taken if `Predicate.evaluate(op, actual, expected)`
    is true. A false result raises `ConditionNotMet` which prunes the downstream
    subgraph. Supported ops: `eq`, `neq`, `gt`, `lt`, `gte`, `lte`, `not_empty`,
    `empty`, `in`.
  - `mapping` — optional map of `target_key => source_key` string pairs. Renames
    keys in the upstream fact before passing them to the downstream node. Source
    keys consumed by the mapping are excluded from the output; unmapped keys are
    passed through unchanged.

  Both `condition` and `mapping` are stored in the existing JSONB column — no
  database migration is required.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.EdgeCondition

  @primary_key false

  embedded_schema do
    field :from, :string
    field :to, :string
    field :condition, :map
    field :mapping, :map, default: %{}
  end

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:from, :to, :condition, :mapping])
    |> validate_required([:from, :to])
    |> validate_condition()
    |> validate_mapping()
  end

  defp validate_condition(changeset) do
    case get_field(changeset, :condition) do
      nil -> changeset
      %{} = c -> validate_condition_map(changeset, c)
    end
  end

  defp validate_condition_map(changeset, c) do
    cond_cs = EdgeCondition.changeset(c)

    if cond_cs.valid? do
      changeset
    else
      Enum.reduce(cond_cs.errors, changeset, fn {key, {msg, _}}, cs ->
        add_error(cs, :condition, "#{key} #{msg}")
      end)
    end
  end

  defp validate_mapping(changeset) do
    case get_field(changeset, :mapping) do
      nil ->
        changeset

      %{} = m ->
        valid =
          Enum.all?(m, fn {k, v} ->
            is_binary(k) and k != "" and is_binary(v) and v != ""
          end)

        if valid,
          do: changeset,
          else: add_error(changeset, :mapping, "keys and values must be non-empty strings")
    end
  end
end
