defmodule Zaq.Engine.Workflows.Conditions.FieldComparison do
  @moduledoc """
  Generic inline condition action for workflow DAGs.

  Reads a single field from the accumulated fact and evaluates it against a
  value using a comparison operator. On pass, returns a structured result with
  logs. On fail, raises `ConditionNotMet` — Runic skips all downstream nodes,
  and `ActionWrapper` records the step as `"skipped"` rather than `"failed"`.

  Supported ops: `eq`, `neq`, `gt`, `lt`, `gte`, `lte`, `not_empty`, `empty`,
  `in` (value must be a list).

  The `field` is looked up from the merged fact in `params` (atom or string key).
  `op` is cast and validated via `Ecto.Enum` — invalid ops are rejected at
  changeset time before evaluation runs.
  """

  use Jido.Action,
    name: "field_comparison",
    schema: [
      field: [type: :string, required: true],
      op: [type: :string, required: true],
      value: [type: :any]
    ],
    output_schema: [
      passed: [type: :boolean, required: true],
      field: [type: :string, required: true],
      actual: [type: :any, required: true]
    ]

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.Conditions.ConditionNotMet

  @primary_key false

  embedded_schema do
    field :field, :string
    field :op, Ecto.Enum, values: [:eq, :neq, :gt, :lt, :gte, :lte, :not_empty, :empty, :in]
  end

  @impl true
  def run(%{field: field, op: op} = params, _context) do
    with {:ok, %{op: cast_op}} <- cast_op(op) do
      expected = Map.get(params, :value)

      atom_key = params |> Map.keys() |> Enum.find(&(is_atom(&1) and Atom.to_string(&1) == field))

      actual =
        case atom_key do
          nil -> Map.get(params, field)
          key -> Map.get(params, key) || Map.get(params, field)
        end

      step_name = Map.get(params, :step_name, "condition")

      logs = [
        %{
          level: "info",
          message:
            "Condition: #{field} #{cast_op} #{inspect(expected)} — actual=#{inspect(actual)}",
          metadata: %{field: field, op: cast_op, expected: expected, actual: actual}
        }
      ]

      if compare(cast_op, actual, expected) do
        {:ok, %{passed: true, field: field, actual: actual}, logs: logs}
      else
        raise ConditionNotMet,
          condition_name: step_name,
          field: field,
          op: cast_op,
          actual: actual,
          expected: expected
      end
    end
  end

  defp cast_op(op) do
    %__MODULE__{}
    |> cast(%{op: op}, [:op])
    |> validate_required([:op])
    |> apply_action(:validate)
    |> case do
      {:ok, struct} -> {:ok, struct}
      {:error, cs} -> {:error, "invalid condition op #{inspect(op)}: #{format_errors(cs)}"}
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)
    end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
  end

  defp compare(:eq, a, b), do: a == b
  defp compare(:neq, a, b), do: a != b
  defp compare(:gt, a, b) when is_number(a) and is_number(b), do: a > b
  defp compare(:lt, a, b) when is_number(a) and is_number(b), do: a < b
  defp compare(:gte, a, b) when is_number(a) and is_number(b), do: a >= b
  defp compare(:lte, a, b) when is_number(a) and is_number(b), do: a <= b
  defp compare(:not_empty, a, _), do: not (is_nil(a) or a == [] or a == "")
  defp compare(:empty, a, _), do: is_nil(a) or a == [] or a == ""
  defp compare(:in, a, b) when is_list(b), do: a in b
end
