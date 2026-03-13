defmodule ZaqWeb.Helpers.DateFormat do
  @moduledoc """
  Shared date/time formatting helpers for BO LiveViews.

  Policy:
  - `format_date/1`     — "March 13, 2026" (%B %d, %Y)
  - `format_datetime/1` — "2026-03-13 14:05" (%Y-%m-%d %H:%M)
  - `format_time/1`     — "14:05" (%H:%M)

  All functions accept `nil` and return "—". `format_date/1` also accepts
  ISO-8601 binary strings (as stored in license payloads).
  """

  @doc "Formats a DateTime or NaiveDateTime as a short date string."
  def format_date(nil), do: "—"

  def format_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%B %d, %Y")
      _ -> date_string
    end
  end

  def format_date(dt), do: Calendar.strftime(dt, "%B %d, %Y")

  @doc "Formats a DateTime or NaiveDateTime as a date-time string."
  def format_datetime(nil), do: "—"
  def format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @doc "Formats a DateTime or NaiveDateTime as a time-only string."
  def format_time(nil), do: "—"
  def format_time(dt), do: Calendar.strftime(dt, "%H:%M")
end
