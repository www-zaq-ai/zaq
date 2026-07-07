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

  ## Date conditions

  A condition may carry an optional `type` of `"date"` or `"datetime"`. When set,
  the comparison ops (`eq`/`neq`/`gt`/`lt`/`gte`/`lte`) coerce **both** operands
  through `Zaq.Engine.Workflows.DateOperand` and compare with `Date.compare/2` /
  `DateTime.compare/2` — chronologically correct, unlike `Kernel` term order which
  sorts `%Date{}`/`%DateTime{}` structs by map key. `empty`/`not_empty` are
  unaffected by `type`.

  The `value` (expected) side accepts an ISO8601 string, a sentinel (`"today"` /
  `"now"`), or a relative map (`%{"from" => "now"|"today", "days" => -7}`) — so
  "older than 7 days" is `type: "date", op: "lt", value: %{"from" => "today",
  "days" => -7}`. With `type` unset (`nil`), evaluation is byte-for-byte the legacy
  `Kernel` path. See `DateOperand` for the operand vocabulary.
  """

  @ops [:eq, :neq, :gt, :lt, :gte, :lte, :not_empty, :empty, :in]
  @types ["date", "datetime"]
  @compare_ops ["eq", "neq", "gt", "lt", "gte", "lte"]

  use Ecto.Schema
  import Ecto.Changeset

  alias Zaq.Engine.Workflows.DateOperand

  @primary_key false

  embedded_schema do
    field :field, :string
    field :op, :string
    field :value, :any, virtual: true
    field :type, :string, virtual: true
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
    |> cast(normalize_attrs(attrs), [:field, :op, :value, :type])
    |> validate_required([:field, :op])
    |> validate_length(:field, min: 1)
    |> validate_inclusion(:op, Enum.map(@ops, &to_string/1))
    |> validate_inclusion(:type, @types)
    |> validate_value()
    |> validate_date_value()
  end

  # Ecto's string type cast rejects atoms. Normalize keys to strings and
  # coerce the op/type values from atom to string so :eq → "eq" passes validation.
  defp normalize_attrs(map) do
    map
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> stringify_atom_value("op")
    |> stringify_atom_value("type")
  end

  defp stringify_atom_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} when is_atom(v) and not is_nil(v) -> Map.put(map, key, to_string(v))
      _ -> map
    end
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

  # When a condition declares a date `type`, the static `value` must resolve
  # through `DateOperand`. `empty`/`not_empty` need no value, so they are exempt.
  defp validate_date_value(changeset) do
    type = get_field(changeset, :type)
    op = get_field(changeset, :op)

    cond do
      type not in @types ->
        changeset

      op in ["empty", "not_empty"] ->
        changeset

      match?({:ok, _}, DateOperand.resolve_expected(get_field(changeset, :value), type)) ->
        changeset

      true ->
        add_error(changeset, :value, "does not resolve to a #{type}")
    end
  end

  @doc """
  Evaluates `actual` against `expected` using `op` (legacy `Kernel` semantics).

  Returns `true` or `false`. Operator and operand validity is checked through
  `changeset/1`; invalid conditions raise `ArgumentError`. Equivalent to
  `evaluate/4` with `type: nil`.
  """
  @spec evaluate(atom() | String.t(), term(), term()) :: boolean()
  def evaluate(op, actual, expected), do: evaluate(op, actual, expected, [])

  @doc """
  Evaluates `actual` against `expected` using `op`, honoring `opts`.

  `opts` may carry:

  - `:type` — `"date"` / `"datetime"` (or the atom form). When set, comparison ops
    coerce both operands through `DateOperand` and compare chronologically; an
    operand that cannot be resolved yields `false` (the branch is pruned, never a
    crash). `empty`/`not_empty` ignore `type`. When `nil`/absent, the legacy
    `Kernel` path runs unchanged.
  - `:now` — a `%DateTime{}` clock override passed through to `DateOperand` (for
    resolving `"today"`/`"now"`/relative expected values in tests).
  """
  @spec evaluate(atom() | String.t(), term(), term(), keyword()) :: boolean()
  def evaluate(op, actual, expected, opts) do
    case normalize_type(Keyword.get(opts, :type)) do
      nil -> legacy_evaluate(op, actual, expected)
      type -> date_evaluate(normalize_op(op), actual, expected, type, opts)
    end
  end

  defp legacy_evaluate(op, actual, expected) do
    op = validate_for_evaluation!(op, expected)
    operator_evaluators() |> Map.fetch!(op) |> then(& &1.(actual, expected))
  end

  defp date_evaluate("empty", actual, _expected, _type, _opts), do: runtime_empty?(actual)
  defp date_evaluate("not_empty", actual, _expected, _type, _opts), do: not runtime_empty?(actual)

  defp date_evaluate(op, actual, expected, type, opts) when op in @compare_ops do
    with {:ok, a} <- DateOperand.coerce_actual(actual, type),
         {:ok, e} <- DateOperand.resolve_expected(expected, type, opts) do
      compare_dates(op, a, e, type)
    else
      _ -> false
    end
  end

  # `in` (or any non-date op) with a `type` set: fall back to legacy semantics.
  defp date_evaluate(op, actual, expected, _type, _opts),
    do: legacy_evaluate(op, actual, expected)

  defp compare_dates(op, a, e, type) do
    cmp =
      case type do
        "date" -> Date.compare(a, e)
        "datetime" -> DateTime.compare(a, e)
      end

    case op do
      "eq" -> cmp == :eq
      "neq" -> cmp != :eq
      "gt" -> cmp == :gt
      "lt" -> cmp == :lt
      "gte" -> cmp in [:gt, :eq]
      "lte" -> cmp in [:lt, :eq]
    end
  end

  defp normalize_type(nil), do: nil
  defp normalize_type(type) when type in @types, do: type
  defp normalize_type(type) when is_atom(type), do: normalize_type(to_string(type))
  defp normalize_type(_type), do: nil

  defp normalize_op(op) when is_atom(op), do: to_string(op)
  defp normalize_op(op) when is_binary(op), do: op

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
