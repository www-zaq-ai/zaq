defmodule Zaq.Engine.Workflows.EdgeCondition do
  @moduledoc """
  Embedded value object for edge-condition validation and pure evaluation.

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

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :field, :string
    field :op, :string
    field :value, :any, virtual: true
  end

  @doc "Returns the list of supported operator atoms."
  @spec ops() :: [atom()]
  def ops, do: @ops

  @doc """
  Validates a raw condition map (string or atom keys).

  Returns a changeset so callers can reuse standard Ecto error handling. The
  runtime representation is still the original map stored in workflow JSONB;
  this embedded schema is only the validation contract for that map.
  """
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs) do
    %__MODULE__{}
    |> cast(normalize_attrs(attrs), [:field, :op, :value])
    |> validate_required([:field, :op])
    |> validate_length(:field, min: 1)
    |> validate_inclusion(:op, Enum.map(@ops, &to_string/1))
    |> validate_value()
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

  defp validate_value(changeset) do
    case get_field(changeset, :op) do
      "in" ->
        value = get_field(changeset, :value)

        if is_list(value),
          do: changeset,
          else: add_error(changeset, :value, "must be a list when op is in")

      _ ->
        changeset
    end
  end

  @doc """
  Evaluates `actual` against `expected` using `op`.

  Returns `true` or `false`. Operator and operand validity is checked through
  `changeset/1`; invalid conditions raise `ArgumentError`.
  """
  @spec evaluate(atom() | String.t(), term(), term()) :: boolean()
  def evaluate(op, actual, expected) do
    op = validate_for_evaluation!(op, expected)
    operator_evaluators() |> Map.fetch!(op) |> then(& &1.(actual, expected))
  end

  defp operator_evaluators do
    %{
      "eq" => &Kernel.==/2,
      "neq" => &Kernel.!=/2,
      "gt" => &Kernel.>/2,
      "lt" => &Kernel.</2,
      "gte" => &Kernel.>=/2,
      "lte" => &Kernel.<=/2,
      "not_empty" => fn actual, _expected -> not runtime_empty?(actual) end,
      "empty" => fn actual, _expected -> runtime_empty?(actual) end,
      "in" => fn actual, expected -> actual in expected end
    }
  end

  defp validate_for_evaluation!(op, expected) do
    changeset(%{field: "__runtime__", op: op, value: expected})
    |> case do
      %{valid?: true} = changeset ->
        get_field(changeset, :op)

      changeset ->
        raise ArgumentError, "invalid edge condition: #{inspect(changeset.errors)}"
    end
  end

  @doc false
  @spec runtime_empty?(term()) :: boolean()
  def runtime_empty?(nil), do: true
  # A struct (e.g. %Zaq.Contracts.Record{}) is a present domain value, not a
  # collection — and it does not implement `Enumerable`, so `Enum.empty?/1` would
  # raise. Treat any struct as non-empty before the generic map/list check.
  def runtime_empty?(value) when is_struct(value), do: false
  def runtime_empty?(value) when is_list(value) or is_map(value), do: Enum.empty?(value)

  def runtime_empty?(value) when is_binary(value), do: String.trim(value) == ""
  def runtime_empty?(_value), do: false
end
