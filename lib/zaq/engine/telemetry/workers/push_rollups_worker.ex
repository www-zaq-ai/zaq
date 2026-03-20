defmodule Zaq.Engine.Telemetry.Workers.PushRollupsWorker do
  @moduledoc """
  Pushes local telemetry rollups to the remote benchmark collection API.

  Runs asynchronously in a dedicated queue so remote network operations never
  impact BO rendering or ingestion/message pipelines.
  """

  use Oban.Worker, queue: :telemetry_remote, max_attempts: 5

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.BenchmarkConnector.HTTP

  @cursor_key "telemetry.push_cursor"

  @impl Oban.Worker
  def perform(_job) do
    if sync_enabled?(), do: push_rollups_from_cursor(), else: :ok
  end

  defp push_rollups_from_cursor do
    cursor = Telemetry.get_cursor(@cursor_key)

    case Telemetry.list_local_rollups_since(cursor, 1_000) do
      [] -> :ok
      rollups -> push_rollups_and_advance_cursor(rollups)
    end
  end

  defp push_rollups_and_advance_cursor(rollups) do
    payload = %{
      org: Telemetry.organization_profile(),
      rollups: Enum.map(rollups, &to_wire_rollup/1)
    }

    with :ok <- connector().push_rollups(payload),
         %DateTime{} = last <- List.last(rollups).updated_at,
         {:ok, _} <- Telemetry.put_cursor(@cursor_key, last) do
      :ok
    end
  end

  defp sync_enabled?, do: Telemetry.telemetry_enabled?() and Telemetry.benchmark_opt_in?()

  defp connector do
    Application.get_env(:zaq, :telemetry_benchmark_connector, HTTP)
  end

  defp to_wire_rollup(rollup) do
    %{
      metric_key: rollup.metric_key,
      bucket_start: DateTime.to_iso8601(rollup.bucket_start),
      bucket_size: rollup.bucket_size,
      source: rollup.source,
      dimensions: rollup.dimensions,
      value_sum: rollup.value_sum,
      value_count: rollup.value_count,
      value_min: rollup.value_min,
      value_max: rollup.value_max,
      last_value: rollup.last_value,
      last_at: DateTime.to_iso8601(rollup.last_at)
    }
  end
end
