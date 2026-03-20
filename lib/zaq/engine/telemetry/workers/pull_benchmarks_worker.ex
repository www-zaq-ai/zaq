defmodule Zaq.Engine.Telemetry.Workers.PullBenchmarksWorker do
  @moduledoc """
  Pulls cohort benchmark rollups from remote API and stores them locally.
  """

  use Oban.Worker, queue: :telemetry_remote, max_attempts: 5

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.BenchmarkConnector.HTTP

  @cursor_key "telemetry.pull_cursor"

  @impl Oban.Worker
  def perform(_job) do
    if sync_enabled?(), do: pull_and_store_rollups(), else: :ok
  end

  defp pull_and_store_rollups do
    request = benchmark_request(Telemetry.get_cursor(@cursor_key))

    with {:ok, %{"rollups" => rows} = body} <- connector().pull_rollups(request),
         {_count, _} <- Telemetry.upsert_benchmark_rollups(rows),
         {:ok, _} <- maybe_update_cursor(body, rows) do
      :ok
    end
  end

  defp benchmark_request(cursor) do
    %{
      org: Telemetry.organization_profile(),
      since: if(cursor, do: DateTime.to_iso8601(cursor), else: nil)
    }
  end

  defp sync_enabled?, do: Telemetry.telemetry_enabled?() and Telemetry.benchmark_opt_in?()

  defp connector do
    Application.get_env(:zaq, :telemetry_benchmark_connector, HTTP)
  end

  defp maybe_update_cursor(%{"cursor" => cursor}, _rows) when is_binary(cursor) do
    with {:ok, dt, _} <- DateTime.from_iso8601(cursor) do
      Telemetry.put_cursor(@cursor_key, dt)
    end
  end

  defp maybe_update_cursor(_body, rows) do
    rows
    |> Enum.map(&(&1["last_at"] || &1[:last_at]))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&parse_last_at/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix/1, fn -> nil end)
    |> case do
      nil -> {:ok, :noop}
      dt -> Telemetry.put_cursor(@cursor_key, dt)
    end
  end

  defp parse_last_at(%DateTime{} = dt), do: dt

  defp parse_last_at(binary) when is_binary(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_last_at(_), do: nil
end
