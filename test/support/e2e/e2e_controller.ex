defmodule ZaqWeb.E2EController do
  @moduledoc false

  use ZaqWeb, :controller

  alias Zaq.E2E.{LogCollector, ProcessorState}
  alias Zaq.Engine.Telemetry

  @e2e_enabled Application.compile_env(:zaq, :e2e, false)

  # Final safety net — routes compile away in prod, but this guards at action level too.
  def action(conn, _) do
    if @e2e_enabled do
      apply(__MODULE__, action_name(conn), [conn, conn.params])
    else
      conn |> put_status(:not_found) |> json(%{error: "not found"}) |> halt()
    end
  end

  # GET /e2e/processor/fail
  def fail(conn, params) do
    count = params |> Map.get("count", "1") |> String.to_integer()
    ProcessorState.set_fail(count)
    json(conn, %{ok: true, fail_count: count})
  end

  # GET /e2e/processor/reset
  def reset(conn, _params) do
    ProcessorState.reset()
    json(conn, %{ok: true})
  end

  # GET /e2e/health
  def health(conn, _params) do
    json(conn, %{
      status: "ok",
      env: "test",
      e2e: true,
      node: node()
    })
  end

  # GET /e2e/telemetry/points?metric=ingestion.*&limit=50&last_minutes=5
  def telemetry_points(conn, params) do
    points = Telemetry.list_recent_points(params)
    metric = Map.get(params, "metric", "")

    json(conn, %{
      points: Enum.map(points, &serialize_point/1),
      count: length(points),
      metric: metric
    })
  end

  # GET /e2e/logs/recent?level=error&limit=20
  def logs_recent(conn, params) do
    limit = params |> Map.get("limit", "100") |> parse_int(100)
    level = Map.get(params, "level", nil)

    opts = [limit: limit] ++ if(level, do: [level: level], else: [])
    logs = LogCollector.recent(opts)

    json(conn, %{
      logs: Enum.map(logs, &serialize_log/1),
      count: length(logs)
    })
  end

  defp serialize_point(point) do
    %{
      metric_key: point.metric_key,
      value: point.value,
      occurred_at: DateTime.to_iso8601(point.occurred_at),
      dimensions: point.dimensions,
      source: point.source,
      node: point.node
    }
  end

  defp serialize_log(entry) do
    %{
      level: entry.level,
      message: entry.message,
      timestamp: DateTime.to_iso8601(entry.timestamp)
    }
  end

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default
end
