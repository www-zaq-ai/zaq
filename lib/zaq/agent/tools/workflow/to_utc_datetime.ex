defmodule Zaq.Agent.Tools.Workflow.ToUtcDateTime do
  @moduledoc """
  Converts a delay or timezone-qualified datetime into a UTC ISO8601 datetime.

  This action is intentionally generic. It knows nothing about scheduling; callers
  can map its `datetime` output into any downstream action that needs a UTC
  timestamp.

  Delay input example:

      %{delay: %{amount: 15, unit: "minutes"}}

  Datetime input example:

      %{datetime: "2026-07-15T12:00:00+02:00"}
  """

  use Zaq.Engine.Workflows.Action,
    name: "to_utc_datetime",
    description: "Convert a delay or timezone-qualified datetime to a UTC ISO8601 datetime.",
    schema: [
      datetime: [
        type: :string,
        required: false,
        doc:
          "ISO8601 datetime. Include a timezone offset, or provide timezone=UTC for naive input."
      ],
      timezone: [
        type: :string,
        required: false,
        doc:
          "Timezone for naive datetime input. Only UTC/Etc/UTC is supported without extra deps."
      ],
      delay: [
        type: :map,
        required: false,
        doc:
          "Delay map with amount and unit, e.g. %{amount: 15, unit: \"minutes\"}. Supported units: second, minute, hour, day."
      ]
    ],
    output_schema: [
      datetime: [
        type: :string,
        required: true,
        doc: "UTC ISO8601 datetime."
      ]
    ]

  @units %{
    "second" => 1,
    "seconds" => 1,
    "minute" => 60,
    "minutes" => 60,
    "hour" => 3_600,
    "hours" => 3_600,
    "day" => 86_400,
    "days" => 86_400
  }

  @impl Jido.Action
  def run(params, context) do
    datetime = get(params, :datetime)
    delay = get(params, :delay)

    case {present?(datetime), is_map(delay)} do
      {true, false} -> convert_datetime(datetime, get(params, :timezone))
      {false, true} -> convert_delay(delay, context)
      {false, false} -> {:error, "provide either datetime or delay"}
      {true, true} -> {:error, "provide only one of datetime or delay"}
    end
  end

  defp convert_datetime(datetime, timezone) do
    case DateTime.from_iso8601(datetime) do
      {:ok, utc_datetime, _offset} ->
        {:ok, %{datetime: DateTime.to_iso8601(utc_datetime)}}

      {:error, _} ->
        convert_naive_datetime(datetime, timezone)
    end
  end

  defp convert_naive_datetime(datetime, timezone) when timezone in ["UTC", "Etc/UTC"] do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(datetime),
         {:ok, utc_datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      {:ok, %{datetime: DateTime.to_iso8601(utc_datetime)}}
    else
      _ -> {:error, "invalid datetime"}
    end
  end

  defp convert_naive_datetime(_datetime, _timezone) do
    {:error, "datetime must include a timezone offset or timezone must be UTC"}
  end

  defp convert_delay(delay, context) do
    with {:ok, amount} <- delay_amount(delay),
         {:ok, seconds_per_unit} <- delay_unit(delay) do
      datetime =
        context
        |> Map.get(:now, DateTime.utc_now())
        |> DateTime.add(amount * seconds_per_unit, :second)

      {:ok, %{datetime: DateTime.to_iso8601(datetime)}}
    end
  end

  defp delay_amount(delay) do
    case get(delay, :amount) do
      amount when is_integer(amount) and amount > 0 -> {:ok, amount}
      _ -> {:error, "delay.amount must be a positive integer"}
    end
  end

  defp delay_unit(delay) do
    unit = delay |> get(:unit) |> to_string()

    case Map.fetch(@units, unit) do
      {:ok, seconds} -> {:ok, seconds}
      :error -> {:error, "delay.unit must be second, minute, hour, or day"}
    end
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
