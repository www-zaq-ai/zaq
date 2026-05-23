defmodule Zaq.Contracts.Sheets.Range do
  @moduledoc "Helpers to normalize and validate A1-style ranges."

  @a1_regex ~r/^[^!]+![A-Z]+\d+(?::[A-Z]+\d+)?$/

  @spec normalize(term()) :: String.t() | nil
  def normalize(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  def normalize(_), do: nil

  @spec valid_a1?(term()) :: boolean()
  def valid_a1?(value) when is_binary(value), do: Regex.match?(@a1_regex, String.trim(value))
  def valid_a1?(_), do: false
end
