defmodule ZaqWeb.Helpers.TelemetryFormat do
  @moduledoc """
  Shared number formatting for BO telemetry KPIs and charts.
  """

  @spec format_value(term()) :: String.t()
  def format_value(nil), do: "--"

  def format_value(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(.{3})(?=.)/, "\\1,")
    |> String.reverse()
  end

  def format_value(value) when is_float(value) do
    rounded = Float.round(value, 2)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 2)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
    end
  end

  def format_value(value), do: to_string(value)

  @spec format_trend_percent(number()) :: String.t()
  def format_trend_percent(value) when value >= 0, do: "+#{round2(value)}%"
  def format_trend_percent(value), do: "#{round2(value)}%"

  @spec round2(number()) :: float()
  def round2(value), do: Float.round(value * 1.0, 2)
end
