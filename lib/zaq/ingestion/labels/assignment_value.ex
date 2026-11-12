defmodule Zaq.Ingestion.Labels.AssignmentValue do
  @moduledoc "Typed label values, stored in a JSON envelope and validated against their definition."
  use Ecto.Type

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(value), do: if(valid?(value), do: {:ok, value}, else: :error)

  @impl Ecto.Type
  def load(%{"value" => value}), do: cast(value)
  def load(nil), do: {:ok, nil}
  def load(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}
  def dump(value), do: if(valid?(value), do: {:ok, %{"value" => value}}, else: :error)

  @doc "Checks the native value shape, independently of a definition."
  def valid?(nil), do: true
  def valid?(value) when is_boolean(value) or is_number(value), do: true

  def valid?(value) when is_binary(value),
    do: String.valid?(value) and String.length(value) <= 200

  def valid?(_), do: false

  @doc "Values are native scalars; option IDs are never coerced or renamed."
  def normalize(value), do: value

  @doc "Comparison key for JSON numeric equality, preserving exact nonnumeric values."
  def equality_key(value) when is_number(value) do
    {coefficient, exponent} = decimal_parts(value)
    numeric_key(coefficient, exponent)
  end

  def equality_key(value), do: {:scalar, value}

  @doc "Validates an assigned value; absence is represented by state rather than a value."
  def valid_for?(%{value_type: "boolean"}, value), do: is_boolean(value)

  def valid_for?(%{value_type: "scale", value_config: config}, value) when is_number(value) do
    with %{"min" => minimum, "max" => maximum, "increment" => increment} <- config,
         true <- Enum.all?([minimum, maximum, increment], &is_number/1),
         true <- increment > 0 do
      [value, minimum, maximum, increment] = integer_grid([value, minimum, maximum, increment])
      value >= minimum and value <= maximum and rem(value - minimum, increment) == 0
    else
      _ -> false
    end
  end

  def valid_for?(%{value_type: "options", value_config: %{"options" => options}}, value)
      when is_binary(value) and is_list(options),
      do: Enum.any?(options, &match?(%{"id" => ^value}, &1))

  def valid_for?(_, _), do: false

  # Convert decimal representations to one integer unit before arithmetic. Decimal
  # arithmetic uses a process precision context and can round large grid offsets.
  defp integer_grid(values) do
    parts = Enum.map(values, &decimal_parts/1)
    exponent = parts |> Enum.map(&elem(&1, 1)) |> Enum.min()

    Enum.map(parts, fn {coefficient, scale} -> coefficient * Integer.pow(10, scale - exponent) end)
  end

  defp decimal_parts(value) when is_integer(value), do: {value, 0}

  defp decimal_parts(value) do
    %Decimal{sign: sign, coef: coefficient, exp: exponent} = Decimal.from_float(value)
    {sign * coefficient, exponent}
  end

  defp numeric_key(0, _exponent), do: {:number, 0, 0}

  defp numeric_key(coefficient, exponent) when rem(coefficient, 10) == 0,
    do: numeric_key(div(coefficient, 10), exponent + 1)

  defp numeric_key(coefficient, exponent), do: {:number, coefficient, exponent}
end
