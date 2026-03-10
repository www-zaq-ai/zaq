defmodule ZaqWeb.TelemetryTest do
  use ExUnit.Case, async: true

  alias ZaqWeb.Telemetry, as: WebTelemetry

  test "init/1 configures telemetry poller child" do
    assert {:ok, {spec, [child]}} = WebTelemetry.init([])

    assert spec.strategy == :one_for_one
    assert child.id == :telemetry_poller
  end

  test "metrics/0 includes phoenix, repo, and vm metrics" do
    metrics = WebTelemetry.metrics()

    assert Enum.any?(metrics, fn
             %Telemetry.Metrics.Summary{name: [:phoenix, :endpoint, :start, :system_time]} -> true
             _ -> false
           end)

    assert Enum.any?(metrics, fn
             %Telemetry.Metrics.Summary{name: [:zaq, :repo, :query, :total_time]} -> true
             _ -> false
           end)

    assert Enum.any?(metrics, fn
             %Telemetry.Metrics.Summary{name: [:vm, :memory, :total]} -> true
             _ -> false
           end)
  end
end
