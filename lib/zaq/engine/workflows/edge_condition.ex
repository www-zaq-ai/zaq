defmodule Zaq.Engine.Workflows.EdgeCondition do
  @moduledoc """
  Single home for the edge-condition operator vocabulary and pure evaluation.

  Used by `Step.Edge` for schema validation and by `Steps.EdgeStep`
  for runtime evaluation.

  ## Supported operators

  | Op         | Description                            |
  |------------|----------------------------------------|
  | `eq`       | equal (`==`)                           |
  | `neq`      | not equal (`!=`)                       |
  | `gt`       | greater than                           |
  | `lt`       | less than                              |
  | `gte`      | greater than or equal                  |
  | `lte`      | less than or equal                     |
  | `not_empty`| truthy and non-blank                   |
  | `empty`    | nil, `""`, `[]`, or `%{}`             |
  | `in`       | membership (`expected` must be a list) |
  """

  @ops [:eq, :neq, :gt, :lt, :gte, :lte, :not_empty, :empty, :in]

  import Ecto.Changeset

  @doc "Returns the list of supported operator atoms."
  @spec ops() :: [atom()]
  def ops, do: @ops

  @doc """
  Validates a raw condition map (string or atom keys) using a schemaless Ecto
  changeset. Returns a changeset — inspect `.valid?` and `.errors` as needed.
  """
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    types = %{field: :string, op: :string}

    {%{field: nil, op: nil}, types}
    |> cast(normalize_attrs(attrs), [:field, :op])
    |> validate_required([:field, :op])
    |> validate_length(:field, min: 1)
    |> validate_inclusion(:op, Enum.map(@ops, &to_string/1))
  end

  # Ecto's string type cast rejects atoms. Normalize keys to strings and
  # coerce the op value from atom to string so :eq → "eq" passes validation.
  defp normalize_attrs(map) do
    map
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.update("op", nil, fn
      op when is_atom(op) -> to_string(op)
      op -> op
    end)
  end

  @doc """
  Evaluates `actual` against `expected` using `op`.

  Returns `true` or `false`. Raises `ArgumentError` for unknown ops.
  `:in` requires `expected` to be a list; raises `ArgumentError` otherwise.
  """
  @spec evaluate(atom(), term(), term(), keyword()) :: boolean()
  def evaluate(op, actual, expected, opts \\ [])

  def evaluate(:eq, actual, expected, _opts), do: actual == expected
  def evaluate(:neq, actual, expected, _opts), do: actual != expected
  def evaluate(:gt, actual, expected, _opts), do: actual > expected
  def evaluate(:lt, actual, expected, _opts), do: actual < expected
  def evaluate(:gte, actual, expected, _opts), do: actual >= expected
  def evaluate(:lte, actual, expected, _opts), do: actual <= expected
  def evaluate(:not_empty, actual, _expected, _opts), do: not empty?(actual)
  def evaluate(:empty, actual, _expected, _opts), do: empty?(actual)

  def evaluate(:in, actual, expected, _opts) when is_list(expected), do: actual in expected

  def evaluate(:in, _actual, expected, _opts),
    do: raise(ArgumentError, "op :in requires a list expected value, got: #{inspect(expected)}")

  def evaluate(op, _actual, _expected, _opts),
    do: raise(ArgumentError, "unknown edge condition op: #{inspect(op)}")

  defp empty?(nil), do: true
  defp empty?(""), do: true
  defp empty?([]), do: true
  defp empty?(%{} = m) when map_size(m) == 0, do: true
  defp empty?(_), do: false
end
