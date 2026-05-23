defmodule Zaq.Contracts.Sheets.Coercion do
  @moduledoc "Basic scalar coercion helpers for sheet matrix values."

  @spec scalar(term()) :: String.t() | number() | boolean() | nil
  def scalar(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: value

  def scalar(value) when is_atom(value), do: Atom.to_string(value)
  def scalar(value), do: inspect(value)
end
