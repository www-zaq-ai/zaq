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

  alias ZaqWeb.Helpers.Timezone

  @doc "Formats a DateTime or NaiveDateTime as a short date string."
  def format_date(nil), do: "—"

  def format_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%B %d, %Y")
      _ -> date_string
    end
  end

  def format_date(dt), do: Calendar.strftime(dt, "%B %d, %Y")

  @doc "Formats a DateTime or NaiveDateTime as a date-time string, converted to system timezone."
  def format_datetime(nil), do: "—"

  def format_datetime(%DateTime{} = dt) do
    dt
    |> Timezone.shift()
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  def format_datetime(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y-%m-%d %H:%M")
  end

  @doc "Formats a DateTime or NaiveDateTime as a date-time string with seconds, converted to system timezone."
  def format_datetime_seconds(nil), do: "—"

  def format_datetime_seconds(%DateTime{} = dt) do
    dt
    |> Timezone.shift()
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  def format_datetime_seconds(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%Y-%m-%d %H:%M:%S")
  end

  @doc "Formats a DateTime or NaiveDateTime as a time-only string, converted to system timezone."
  def format_time(nil), do: "—"

  def format_time(%DateTime{} = dt) do
    dt
    |> Timezone.shift()
    |> Calendar.strftime("%H:%M")
  end

  def format_time(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%H:%M")
  end

  @doc """
  Injects `%{type: :date_separator, date: Date.t()}` entries before the first
  message of each calendar day. `key` is the atom used to read the timestamp
  from each message map (default `:timestamp`).
  """
  def inject_date_separators(messages, key \\ :timestamp) do
    {result, _} =
      Enum.reduce(messages, {[], nil}, fn msg, {acc, last_date} ->
        date = msg |> Map.get(key) |> to_local_date()

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

  defp to_local_date(%DateTime{} = timestamp) do
    shifted = Timezone.shift(timestamp)
    Date.new!(shifted.year, shifted.month, shifted.day)
  end

  defp to_local_date(timestamp), do: to_date(timestamp)
end
