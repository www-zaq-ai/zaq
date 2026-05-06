defmodule Zaq.Utils.DateUtils do
  @moduledoc false

  @doc """
  Formats a `DateTime` or `NaiveDateTime` as a seconds-precision ISO-8601 string.

  Returns `"unknown time"` for any other value.
  """
  @spec format_ts(DateTime.t() | NaiveDateTime.t() | any()) :: String.t()
  def format_ts(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> DateTime.to_string()

  def format_ts(%NaiveDateTime{} = dt),
    do: dt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()

  def format_ts(_), do: "unknown time"
end
