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

  @valid_ops Enum.map(EdgeCondition.ops(), &to_string/1)

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
    field = to_string_key(c, "field")
    op_str = c |> to_string_key("op") |> normalize_op()

    cond do
      is_nil(field) or field == "" -> add_error(changeset, :condition, "field is required")
      is_nil(op_str) or op_str == "" -> add_error(changeset, :condition, "op is required")
      op_str not in @valid_ops -> add_error(changeset, :condition, "unknown op: #{op_str}")
      true -> changeset
    end
  end

  defp normalize_op(nil), do: nil
  defp normalize_op(op), do: to_string(op)

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

  # Looks up a key in a map trying both string and atom forms.
  # Keys are always bounded ("field", "op") so String.to_atom/1 is safe.
  defp to_string_key(map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end
end
