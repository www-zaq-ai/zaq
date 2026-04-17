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

  @doc """
  Injects `%{type: :date_separator, date: Date.t()}` entries before the first
  message of each calendar day. `key` is the atom used to read the timestamp
  from each message map (default `:timestamp`).
  """
  def inject_date_separators(messages, key \\ :timestamp) do
    {result, _} =
      Enum.reduce(messages, {[], nil}, fn msg, {acc, last_date} ->
        date = msg |> Map.get(key) |> to_date()

        if date && date != last_date do
          {[msg, %{type: :date_separator, date: date} | acc], date}
        else
          {[msg | acc], last_date}
        end
      end)

    Enum.reverse(result)
  end

  @doc """
  Injects `%{type: :date_separator, label: String.t()}` entries before the
  first item of each relative-date group ("Today", "Yesterday", "Last week",
  or a formatted date for older). `key` is the atom used to read the
  timestamp from each item map (default `:inserted_at`).
  """
  def inject_relative_date_separators(items, key \\ :inserted_at) do
    {result, _} =
      Enum.reduce(items, {[], nil}, fn item, {acc, last_label} ->
        label = item |> Map.get(key) |> to_date() |> relative_date_label()

        if label && label != last_label do
          {[item, %{type: :date_separator, label: label} | acc], label}
        else
          {[item | acc], last_label}
        end
      end)

    Enum.reverse(result)
  end

  @doc "Returns a human-friendly relative label for a date: Today, Yesterday, Last week, or a formatted date."
  def relative_date_label(nil), do: nil

  def relative_date_label(date) do
    diff = Date.diff(Date.utc_today(), date)

    cond do
      diff == 0 -> "Today"
      diff == 1 -> "Yesterday"
      diff <= 7 -> "Last week"
      true -> format_date(date)
    end
  end

  defp to_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp to_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)
  defp to_date(_), do: nil
end
