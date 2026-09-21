defmodule ZaqWeb.Live.BO.LLMPerformanceFailureTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveView.Socket
  alias Zaq.Engine.Telemetry.Contracts.DashboardChart
  alias ZaqWeb.Live.BO.EngineDispatch
  alias ZaqWeb.Live.BO.LLMPerformanceLive

  @filters %{range: "7d", model_sort: "tokens", people_sort: "tokens", agent_id: nil}
  @labels ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00"]

  test "rescues telemetry database failures and renders empty 24h defaults" do
    assert Process.whereis(Zaq.Engine.Supervisor)

    assert_raise DBConnection.OwnershipError, fn ->
      EngineDispatch.dispatch(:telemetry_load_llm_performance, @filters)
    end

    assert {:ok, socket} = LLMPerformanceLive.mount(%{}, %{}, %Socket{})
    assert socket.assigns.range == "7d"

    socket = disconnected_set_range(socket, "24h")
    assert socket.assigns.range == "24h"
    assert socket.assigns.top_models == []
    assert socket.assigns.top_people == []
    assert socket.assigns.agents == []

    assert_time_series(socket.assigns.llm_api_calls_chart, "llm_api_calls", ["calls"])

    assert_time_series(socket.assigns.token_usage_chart, "token_usage", [
      "output_tokens",
      "input_tokens"
    ])

    assert_time_series(socket.assigns.agent_llm_api_calls_chart, "agent_llm_api_calls", ["calls"])

    assert_time_series(socket.assigns.agent_token_usage_chart, "agent_token_usage", [
      "output_tokens",
      "input_tokens"
    ])

    retrieval = socket.assigns.retrieval_effectiveness_chart
    assert %DashboardChart{id: "retrieval_effectiveness", kind: :gauge} = retrieval

    assert retrieval.summary == %{
             value: 0.0,
             max: 100.0,
             label: "strict no-answer adjusted"
           }

    assert retrieval.labels == []
    assert retrieval.series == []

    refute_receive :refresh_telemetry
  end

  defp disconnected_set_range(socket, range) do
    {:noreply, socket} = LLMPerformanceLive.handle_event("set_range", %{"range" => range}, socket)
    socket
  end

  defp assert_time_series(chart, id, keys) do
    zeroes = List.duplicate(0.0, length(@labels))

    assert %DashboardChart{id: ^id, kind: :time_series, labels: @labels} = chart
    assert Enum.map(chart.series, & &1.key) == keys
    assert Enum.all?(chart.series, &(&1.values == zeroes))

    assert chart.summary == %{
             labels: @labels,
             values: Map.new(keys, &{&1, zeroes}),
             benchmarks: %{},
             baseline: nil
           }
  end
end
