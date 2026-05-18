defmodule Zaq.Utils.ParseUtils do
  @moduledoc false

  @doc """
  Parses a string to an integer, returning `default` on `nil`, empty string, or parse failure.

  Accepts trailing non-numeric characters (e.g. `"42px"` parses to `42`).
  Use `parse_int_strict/1` when trailing characters should be rejected.

  ## Examples

      iex> Zaq.Utils.ParseUtils.parse_int("42", 0)
      42

      iex> Zaq.Utils.ParseUtils.parse_int("42px", 0)
      42

      iex> Zaq.Utils.ParseUtils.parse_int("abc", 0)
      0

      iex> Zaq.Utils.ParseUtils.parse_int("", 0)
      0

      iex> Zaq.Utils.ParseUtils.parse_int(nil, 0)
      0

  """
  def parse_int(nil, default), do: default
  def parse_int("", default), do: default

  def parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  @doc """
  Parses a string or integer strictly, returning `{:ok, integer}` or `:error`.

  Unlike `parse_int/2`, rejects strings with trailing non-numeric characters.

  ## Examples

      iex> Zaq.Utils.ParseUtils.parse_int_strict("42")
      {:ok, 42}

      iex> Zaq.Utils.ParseUtils.parse_int_strict(42)
      {:ok, 42}

      iex> Zaq.Utils.ParseUtils.parse_int_strict("42px")
      :error

      iex> Zaq.Utils.ParseUtils.parse_int_strict("abc")
      :error

      iex> Zaq.Utils.ParseUtils.parse_int_strict(nil)
      :error

  """
  @spec parse_int_strict(term()) :: {:ok, integer()} | :error
  def parse_int_strict(value) when is_integer(value), do: {:ok, value}

  def parse_int_strict(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def parse_int_strict(_value), do: :error

  @doc """
  Parses an optional integer, returning `nil` for `nil`, blank, or invalid values.

  Accepts integer pass-through and strict string parsing (no trailing characters).

  ## Examples

      iex> Zaq.Utils.ParseUtils.parse_optional_int("42")
      42

      iex> Zaq.Utils.ParseUtils.parse_optional_int(42)
      42

      iex> Zaq.Utils.ParseUtils.parse_optional_int("42px")
      nil

      iex> Zaq.Utils.ParseUtils.parse_optional_int("abc")
      nil

      iex> Zaq.Utils.ParseUtils.parse_optional_int("")
      nil

      iex> Zaq.Utils.ParseUtils.parse_optional_int(nil)
      nil

  """
  @spec parse_optional_int(term()) :: integer() | nil
  def parse_optional_int(nil), do: nil
  def parse_optional_int(""), do: nil
  def parse_optional_int(value) when is_integer(value), do: value

  def parse_optional_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def parse_optional_int(_value), do: nil

  @doc """
  Parses an optional integer with a fallback default.

  Returns the parsed integer when valid, otherwise returns `default`.
  """
  @spec parse_optional_int(term(), term()) :: integer() | term()
  def parse_optional_int(value, default) do
    case parse_optional_int(value) do
      nil -> default
      int -> int
    end
  end

  @doc """
  Parses a float-like value, returning `default` for nil/blank/invalid values.
  """
  @spec parse_float(term(), float()) :: float()
  def parse_float(nil, default), do: default
  def parse_float("", default), do: default

  def parse_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  def parse_float(value, _default) when is_float(value), do: value
  def parse_float(value, _default) when is_integer(value), do: value / 1

  @doc """
  Parses a boolean-like value with a default for nil.

  Accepted true values: `true`, `"true"`, `"1"`, and `1`.
  """
  @spec parse_bool(term(), boolean()) :: boolean()
  def parse_bool(nil, default), do: default
  def parse_bool(value, _default) when value in [true, "true", "1", 1], do: true
  def parse_bool(_value, _default), do: false

  @doc """
  Parses a positive integer, returning `default` for non-positive or invalid values.

  ## Examples

      iex> Zaq.Utils.ParseUtils.parse_positive_int(5, 1)
      5

      iex> Zaq.Utils.ParseUtils.parse_positive_int("5", 1)
      5

      iex> Zaq.Utils.ParseUtils.parse_positive_int("0", 1)
      1

      iex> Zaq.Utils.ParseUtils.parse_positive_int("abc", 1)
      1

  """
  @spec parse_positive_int(term(), pos_integer()) :: pos_integer()
  def parse_positive_int(value, default) when is_integer(default) and default > 0 do
    case parse_int_strict(value) do
      {:ok, int} when int > 0 -> int
      _ -> default
    end
  end
end
