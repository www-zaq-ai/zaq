defmodule Zaq.Engine.Telemetry.Contracts.DashboardChart do
  @behaviour Access
  @moduledoc """
  Canonical telemetry chart envelope used across BO dashboards.

  This envelope is shared for every visualization kind and carries common
  identity fields plus typed payloads.
  """

  alias Zaq.Engine.Telemetry.Contracts.{DisplayMeta, RuntimeMeta}

  alias Zaq.Engine.Telemetry.Contracts.Payloads.{
    CategoryVectorPayload,
    ProgressPayload,
    ScalarListPayload,
    ScalarPayload,
    SeriesPayload,
    StatusListPayload
  }

  @type payload ::
          ScalarPayload.t()
          | ScalarListPayload.t()
          | SeriesPayload.t()
          | CategoryVectorPayload.t()
          | StatusListPayload.t()
          | ProgressPayload.t()
          | map()

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom(),
          title: String.t(),
          labels: list(),
          series: list(),
          summary: map(),
          meta: map(),
          payload: payload(),
          display: DisplayMeta.t(),
          runtime: RuntimeMeta.t()
        }

  defstruct id: "",
            kind: :unknown,
            title: "",
            labels: [],
            series: [],
            summary: %{},
            meta: %{},
            payload: %{},
            display: %DisplayMeta{},
            runtime: %RuntimeMeta{}

  @spec new(map()) :: t()
  def new(%{kind: :metric_cards} = chart), do: build_chart(chart)
  def new(%{"kind" => :metric_cards} = chart), do: build_chart(chart)

  def new(%{kind: :time_series, labels: _labels, series: _series} = chart), do: build_chart(chart)

  def new(%{"kind" => :time_series, "labels" => _labels, "series" => _series} = chart),
    do: build_chart(chart)

  def new(%{kind: :bar} = chart), do: build_chart(chart)
  def new(%{"kind" => :bar} = chart), do: build_chart(chart)

  def new(%{kind: :donut} = chart), do: build_chart(chart)
  def new(%{"kind" => :donut} = chart), do: build_chart(chart)

  def new(%{kind: :radar} = chart), do: build_chart(chart)
  def new(%{"kind" => :radar} = chart), do: build_chart(chart)

  def new(%{kind: :gauge} = chart), do: build_chart(chart)
  def new(%{"kind" => :gauge} = chart), do: build_chart(chart)

  def new(%{kind: :status_grid} = chart), do: build_chart(chart)
  def new(%{"kind" => :status_grid} = chart), do: build_chart(chart)

  def new(%{kind: :progress} = chart), do: build_chart(chart)
  def new(%{"kind" => :progress} = chart), do: build_chart(chart)

  def new(chart) when is_map(chart), do: build_chart(chart)
  def new(_), do: %__MODULE__{}

  @deprecated "Use new/1"
  @spec from_legacy_map(map()) :: t()
  def from_legacy_map(chart), do: new(chart)

  @spec fetch(t(), atom()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{} = chart, key), do: Map.fetch(chart, key)

  @spec get_and_update(t(), atom(), (term() -> {term(), term()} | :pop)) ::
          {term(), t()}
  def get_and_update(%__MODULE__{} = chart, key, function),
    do: Map.get_and_update(chart, key, function)

  @spec pop(t(), atom()) :: {term(), t()}
  def pop(%__MODULE__{} = chart, key), do: Map.pop(chart, key)

  defp build_chart(chart) do
    summary = map_get(chart, :summary, %{})
    kind = map_get(chart, :kind, :unknown)
    meta = map_get(chart, :meta, %{})

    payload = payload_for_kind(kind, chart, summary)
    normalized_summary = normalize_summary(kind, summary, payload)

    %__MODULE__{
      id: map_get(chart, :id, ""),
      kind: kind,
      title: map_get(chart, :title, ""),
      labels: map_get(chart, :labels, []),
      series: map_get(chart, :series, []),
      summary: normalized_summary,
      meta: meta,
      payload: payload,
      display: DisplayMeta.from_map(meta),
      runtime: RuntimeMeta.from_map(meta)
    }
  end

  defp payload_for_kind(:metric_cards, chart, summary) do
    range = chart |> map_get(:meta, %{}) |> map_get(:range, nil)

    summary
    |> map_get(:metrics, [])
    |> Enum.map(fn metric ->
      payload = ScalarPayload.from_map(metric)
      display = Map.get(payload, :display, %DisplayMeta{})
      Map.put(payload, :display, Map.put(display, :range, display.range || range))
    end)
    |> ScalarListPayload.from_items()
  end

  defp payload_for_kind(:time_series, chart, summary) do
    labels = map_get(chart, :labels, [])
    series = map_get(chart, :series, [])

    SeriesPayload.from_parts(
      labels,
      series,
      time_series_benchmarks(map_get(summary, :benchmarks, %{})),
      time_series_baseline(labels, series, map_get(chart, :baseline, nil))
    )
  end

  defp payload_for_kind(:bar, _chart, summary) do
    CategoryVectorPayload.from_parts(map_get(summary, :bars, []))
  end

  defp payload_for_kind(:donut, _chart, summary) do
    CategoryVectorPayload.from_parts(map_get(summary, :segments, []))
  end

  defp payload_for_kind(:radar, _chart, summary) do
    CategoryVectorPayload.from_parts(
      map_get(summary, :axes, []),
      map_get(summary, :benchmark_axes, [])
    )
  end

  defp payload_for_kind(:gauge, _chart, summary), do: ScalarPayload.from_map(summary)

  defp payload_for_kind(:status_grid, _chart, summary) do
    StatusListPayload.from_items(map_get(summary, :items, []))
  end

  defp payload_for_kind(:progress, _chart, summary) do
    ProgressPayload.from_values(map_get(summary, :total, 0), map_get(summary, :remaining, 0))
  end

  defp payload_for_kind(_kind, _chart, summary), do: summary

  defp normalize_summary(:metric_cards, summary, %ScalarListPayload{} = payload) do
    Map.put(summary, :metrics, payload.items)
  end

  defp normalize_summary(:time_series, summary, %SeriesPayload{} = payload) do
    summary
    |> Map.put(:benchmarks, payload.benchmarks)
    |> Map.put(:baseline, payload.baseline)
  end

  defp normalize_summary(_kind, summary, _payload), do: summary

  defp time_series_benchmarks(benchmarks) when is_map(benchmarks), do: benchmarks
  defp time_series_benchmarks(_benchmarks), do: %{}

  defp time_series_baseline(labels, series, baseline) when is_map(baseline) do
    value = map_get(baseline, :value, nil)
    key = normalize_series_key(map_get(baseline, :for, nil))

    if is_number(value) and valid_series_key?(series, key) do
      label =
        baseline
        |> map_get(:label, map_get(baseline, :name, "Baseline"))
        |> to_string()

      %{
        key: key,
        label: label,
        value: value * 1.0,
        values: Enum.map(List.wrap(labels), fn _ -> value * 1.0 end)
      }
    else
      nil
    end
  end

  defp time_series_baseline(_labels, _series, _baseline), do: nil

  defp valid_series_key?(series, key) when is_binary(key) and key != "" do
    series
    |> List.wrap()
    |> Enum.any?(fn item -> normalize_series_key(map_get(item, :key, nil)) == key end)
  end

  defp valid_series_key?(_series, _key), do: false

  defp normalize_series_key(key) when is_binary(key) and key != "", do: key
  defp normalize_series_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_series_key(_key), do: nil

  defp map_get(map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
