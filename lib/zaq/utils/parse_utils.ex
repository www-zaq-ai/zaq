defmodule Zaq.Utils.ParseUtils do
  @moduledoc false

  @doc "Parses a string to an integer, returning `default` on nil, empty string, or parse failure."
  def parse_int(nil, default), do: default
  def parse_int("", default), do: default

  def parse_int(str, default) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> default
    end
  end

  @doc "Parses an integer strictly, returning {:ok, int} or :error."
  @spec parse_int_strict(term()) :: {:ok, integer()} | :error
  def parse_int_strict(value) when is_integer(value), do: {:ok, value}

  def parse_int_strict(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def parse_int_strict(_value), do: :error

  @doc "Parses an optional integer, returning nil for nil/blank/invalid values."
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
end
