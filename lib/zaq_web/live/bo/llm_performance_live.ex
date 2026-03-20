defmodule ZaqWeb.Live.BO.LLMPerformanceLive do
  use ZaqWeb, :live_view

  alias Zaq.Engine.Telemetry
  alias Zaq.NodeRouter

  @ranges ["24h", "7d", "30d", "90d"]
  @refresh_interval_ms 15_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_interval_ms, :refresh_telemetry)

    {:ok,
     socket
     |> assign(:current_path, "/bo/dashboard/llm-performance")
     |> assign(:ranges, @ranges)
     |> assign(:range, "7d")
     |> assign_telemetry()}
  end

  @impl true
  def handle_event("set_range", %{"range" => range}, socket) do
    next_range = if range in @ranges, do: range, else: socket.assigns.range

    {:noreply,
     socket
     |> assign(:range, next_range)
     |> assign_telemetry()}
  end

  @impl true
  def handle_info(:refresh_telemetry, socket) do
    {:noreply, assign_telemetry(socket)}
  end

  defp assign_telemetry(socket) do
    telemetry = load_llm_performance_data(%{range: socket.assigns.range})
    llm_api_calls_chart = Map.get(telemetry, :llm_api_calls_chart, default_llm_api_calls_chart())
    token_usage_chart = Map.get(telemetry, :token_usage_chart, default_token_usage_chart())

    retrieval_effectiveness_chart =
      Map.get(telemetry, :retrieval_effectiveness_chart, default_retrieval_effectiveness_chart())

    socket
    |> assign(:telemetry, telemetry)
    |> assign(:llm_api_calls_chart, llm_api_calls_chart)
    |> assign(:token_usage_chart, token_usage_chart)
    |> assign(:retrieval_effectiveness_chart, retrieval_effectiveness_chart)
    |> assign(:llm_api_call_points, chart_points(llm_api_calls_chart, "calls"))
    |> assign(:output_token_points, chart_points(token_usage_chart, "output_tokens"))
    |> assign(:input_token_points, chart_points(token_usage_chart, "input_tokens"))
  end

  defp chart_points(chart, key) do
    labels = ensure_list(get_in_contract(chart, :labels, []))

    values =
      chart
      |> get_in_contract(:summary, %{})
      |> get_in_contract(:values, %{})
      |> get_in_contract(key, [])
      |> ensure_list()

    values
    |> Enum.with_index()
    |> Enum.map(fn {value, idx} ->
      %{label: Enum.at(labels, idx, "T#{idx + 1}"), value: to_float(value, 0.0)}
    end)
  end

  defp load_llm_performance_data(filters) do
    case NodeRouter.call(:engine, Telemetry, :load_llm_performance, [filters]) do
      %{} = payload -> payload
      _ -> default_payload(filters)
    end
  rescue
    _ -> default_payload(filters)
  end

  defp default_payload(filters) do
    labels = labels_for_range(Map.get(filters, :range, "7d"))

    %{
      filters: %{range: Map.get(filters, :range, "7d")},
      charts: [
        default_llm_api_calls_chart(labels),
        default_token_usage_chart(labels),
        default_retrieval_effectiveness_chart()
      ],
      llm_api_calls_chart: default_llm_api_calls_chart(labels),
      token_usage_chart: default_token_usage_chart(labels),
      retrieval_effectiveness_chart: default_retrieval_effectiveness_chart()
    }
  end

  defp default_llm_api_calls_chart(labels \\ labels_for_range("7d")) do
    zeroes = Enum.map(labels, fn _ -> 0.0 end)

    %{
      id: "llm_api_calls",
      kind: :time_series,
      title: "LLM API calls",
      labels: labels,
      series: [%{key: "calls", name: "API calls", values: zeroes}],
      summary: %{labels: labels, values: %{"calls" => zeroes}},
      meta: %{}
    }
  end

  defp default_token_usage_chart(labels \\ labels_for_range("7d")) do
    zeroes = Enum.map(labels, fn _ -> 0.0 end)

    %{
      id: "token_usage",
      kind: :time_series,
      title: "Token usage",
      labels: labels,
      series: [
        %{key: "output_tokens", name: "Output tokens", values: zeroes},
        %{key: "input_tokens", name: "Input tokens", values: zeroes}
      ],
      summary: %{labels: labels, values: %{"output_tokens" => zeroes, "input_tokens" => zeroes}},
      meta: %{}
    }
  end

  defp default_retrieval_effectiveness_chart do
    %{
      id: "retrieval_effectiveness",
      kind: :gauge,
      title: "Retrieval effectiveness",
      labels: [],
      series: [],
      summary: %{value: 0.0, max: 100.0, label: "strict no-answer adjusted"},
      meta: %{}
    }
  end

  defp labels_for_range("24h"), do: ["00:00", "04:00", "08:00", "12:00", "16:00", "20:00"]
  defp labels_for_range("7d"), do: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  defp labels_for_range("30d"), do: Enum.map(0..9, fn idx -> "D#{idx * 3 + 1}" end)
  defp labels_for_range("90d"), do: Enum.map(1..12, fn idx -> "W#{idx}" end)
  defp labels_for_range(_), do: labels_for_range("7d")

  defp get_in_contract(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_in_contract(map, key, default) when is_map(map) and is_binary(key),
    do: Map.get(map, key, default)

  defp get_in_contract(_value, _key, default), do: default

  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(_), do: []

  defp to_float(value, _default) when is_float(value), do: value
  defp to_float(value, _default) when is_integer(value), do: value * 1.0
  defp to_float(_, default), do: default
end
