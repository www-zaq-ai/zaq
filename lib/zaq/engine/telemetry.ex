defmodule Zaq.Engine.Telemetry do
  @moduledoc """
  Engine telemetry context.

  Responsibilities:
  - Collect and persist runtime telemetry points
  - Aggregate points into rollups via Oban workers
  - Synchronize benchmark datasets with remote API
  - Serve standardized dashboard datasets for BO LiveViews

  Telemetry ingestion and aggregation flow:

  ```text
  [Business Producers]
    - Conversations (qa.* / feedback.*)
    - Ingestion workers (ingestion.*)
            |
            v
       Telemetry.record/4
       (allowlist + normalization)
            |
            v
     Telemetry.Buffer (async)
    (batch flush -> insert_all)
    (best-effort final flush on graceful shutdown)
            |
            v
      telemetry_points (raw)
            |
            v
  AggregateRollupsWorker (Oban)
    - reads cursor telemetry.rollup_cursor
    - groups into 10m buckets
    - upserts rollups
    - advances cursor
            |
            v
     telemetry_rollups (local)
      /                       \
     v                         v
  PushRollupsWorker       DashboardData.load_dashboard/1
  (telemetry.push_cursor)      (BO chart payload)
     |
     v
  remote benchmark API
     |
     v
  PullBenchmarksWorker
  (telemetry.pull_cursor)
     |
     v
  telemetry_rollups (source=benchmark)

  [Native Infra Producer - Optional]
  Collector (Phoenix/Ecto/Oban events) -> Telemetry.record/4 (allow_infra: true)
  Only persisted when telemetry.capture_infra_metrics is enabled.
  ```

  Canonical telemetry contract mapping:

  - Envelope: `Zaq.Engine.Telemetry.Contracts.DashboardChart`
  - Shared metadata:
    - visible: `Zaq.Engine.Telemetry.Contracts.DisplayMeta`
    - runtime: `Zaq.Engine.Telemetry.Contracts.RuntimeMeta`
  - Payload families:
    - `ScalarPayload` -> metric cards, gauge KPIs
    - `ScalarListPayload` -> metric card grids
    - `SeriesPayload` -> time-series charts
    - `CategoryVectorPayload` -> bar, donut, radar charts
    - `StatusListPayload` -> status grid
    - `ProgressPayload` -> progress countdown

  Metric naming conventions:

  - Business metrics (always persisted): `qa.*`, `feedback.*`, `ingestion.*`
  - Infrastructure metrics (opt-in): `repo.*`, `oban.*`, `phoenix.*`
  - Any other prefix is ignored by `record/4`
  """

  import Ecto.Query

  alias Zaq.Engine.Telemetry.{Buffer, DashboardData, Point, Rollup}
  alias Zaq.Repo
  alias Zaq.System

  @bucket_size "10m"
  @default_remote_url "https://telemetry.zaq.ai"
  @business_metric_prefixes ["qa.", "feedback.", "ingestion."]
  @infra_metric_prefixes ["repo.", "oban.", "phoenix."]

  @doc "Records a telemetry point asynchronously."
  @spec record(String.t(), number(), map(), keyword()) :: :ok
  def record(metric_key, value, dimensions \\ %{}, opts \\ [])

  def record(_metric_key, value, _dimensions, _opts) when not is_number(value), do: :ok

  def record(metric_key, _value, _dimensions, _opts) when not is_binary(metric_key), do: :ok

  def record(metric_key, value, dimensions, opts) do
    if persist_metric?(metric_key, opts) do
      Buffer.enqueue(%{
        metric_key: metric_key,
        value: value,
        dimensions: normalize_dimensions(dimensions),
        occurred_at: normalize_occurred_at(Keyword.get(opts, :occurred_at)),
        source: "local"
      })
    else
      :ok
    end
  end

  @doc "Records user feedback telemetry based on a rating value."
  @spec record_feedback(integer(), map(), keyword()) :: :ok
  def record_feedback(rating, dimensions \\ %{}, opts \\ []) do
    reasons = extract_feedback_reasons(dimensions)

    base =
      dimensions
      |> Map.drop([:feedback_reasons, "feedback_reasons"])
      |> normalize_dimensions()

    record("feedback.rating", rating, base, opts)

    if rating <= 2 do
      record("feedback.negative.count", 1, base, opts)

      Enum.each(reasons, fn reason ->
        record(
          "feedback.negative.reason.count",
          1,
          Map.put(base, "feedback_reason", reason),
          opts
        )
      end)
    end

    :ok
  end

  defp extract_feedback_reasons(dimensions) when is_map(dimensions) do
    dimensions
    |> Map.get(:feedback_reasons, Map.get(dimensions, "feedback_reasons", []))
    |> normalize_feedback_reasons()
  end

  defp extract_feedback_reasons(_), do: []

  defp normalize_feedback_reasons(reasons) when is_list(reasons) do
    reasons
    |> Enum.map(&normalize_feedback_reason/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_feedback_reasons(reasons) when is_binary(reasons) do
    reasons
    |> String.split(",", trim: true)
    |> normalize_feedback_reasons()
  end

  defp normalize_feedback_reasons(_), do: []

  defp normalize_feedback_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_feedback_reason(reason) when is_atom(reason),
    do: normalize_feedback_reason(Atom.to_string(reason))

  defp normalize_feedback_reason(_), do: nil

  @doc "Returns a standardized dashboard payload for the provided filters."
  @spec load_dashboard(map()) :: map()
  def load_dashboard(filters), do: DashboardData.load_dashboard(filters)

  @doc "Returns one chart payload by its identifier."
  @spec load_chart(String.t(), map()) :: {:ok, map()} | {:error, :unknown_chart}
  def load_chart(chart_id, filters), do: DashboardData.load_chart(chart_id, filters)

  @doc "Returns LLM performance dashboard payload for the provided filters."
  @spec load_llm_performance(map()) :: map()
  def load_llm_performance(filters), do: DashboardData.load_llm_performance(filters)

  @doc "Returns conversations dashboard payload for the provided filters."
  @spec load_conversations_metrics(map()) :: map()
  def load_conversations_metrics(filters), do: DashboardData.load_conversations_metrics(filters)

  @doc "Returns knowledge base dashboard payload for the provided filters."
  @spec load_knowledge_base_metrics(map()) :: map()
  def load_knowledge_base_metrics(filters), do: DashboardData.load_knowledge_base_metrics(filters)

  @doc "Returns main dashboard metric card payload for the provided filters."
  @spec load_main_dashboard_metrics(map()) :: map()
  def load_main_dashboard_metrics(filters), do: DashboardData.load_main_dashboard_metrics(filters)

  @deprecated "Use load_main_dashboard_metrics/1 and consume metric_cards_chart.summary.metrics"
  @doc "Legacy dashboard KPI helper retained for compatibility during migration."
  @spec dashboard_kpis(integer() | map() | keyword()) :: %{
          documents_ingested_30d: float(),
          qa_avg_response_ms_30d: float(),
          llm_api_calls_30d: non_neg_integer()
        }
  def dashboard_kpis(params \\ 30) do
    days = normalize_days(params)
    range = range_for_days(days)

    metrics =
      %{range: range}
      |> load_main_dashboard_metrics()
      |> get_in([:metric_cards_chart, :summary, :metrics])
      |> List.wrap()

    %{
      documents_ingested_30d: metric_value(metrics, "dashboard-metric-documents-ingested", 0.0),
      qa_avg_response_ms_30d: metric_value(metrics, "dashboard-metric-qa-response-time", 0.0),
      llm_api_calls_30d: round(metric_value(metrics, "dashboard-metric-llm-api-calls", 0.0))
    }
  end

  @doc "Returns recent telemetry points for E2E inspection. Accepts metric (supports * wildcard), limit, and last_minutes."
  @spec list_recent_points(map()) :: [Point.t()]
  def list_recent_points(params \\ %{}) do
    metric = Map.get(params, "metric", "")
    limit = params |> Map.get("limit", "50") |> parse_int(50)
    last_minutes = params |> Map.get("last_minutes", "5") |> parse_int(5)

    since = DateTime.add(DateTime.utc_now(), -last_minutes * 60, :second)
    like_pattern = String.replace(metric, "*", "%")

    base_query =
      from(p in Point,
        where: p.occurred_at >= ^since,
        order_by: [desc: p.occurred_at],
        limit: ^limit
      )

    base_query
    |> maybe_filter_metric(like_pattern)
    |> Repo.all()
  end

  defp maybe_filter_metric(query, ""), do: query

  defp maybe_filter_metric(query, pattern),
    do: from(p in query, where: like(p.metric_key, ^pattern))

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_int(_, default), do: default

  @doc "Returns local rollups updated after the given cursor."
  @spec list_local_rollups_since(DateTime.t() | nil, non_neg_integer()) :: [map()]
  def list_local_rollups_since(cursor, limit \\ 500) do
    base_query =
      from(r in Rollup,
        where: r.source == "local",
        order_by: [asc: r.updated_at],
        limit: ^limit
      )

    base_query
    |> maybe_filter_since(cursor)
    |> Repo.all()
  end

  defp maybe_filter_since(query, nil), do: query

  defp maybe_filter_since(query, %DateTime{} = cursor),
    do: from(r in query, where: r.updated_at > ^cursor)

  @doc "Upserts remote benchmark rollups into local storage."
  @spec upsert_benchmark_rollups([map()]) :: {non_neg_integer(), nil | [term()]}
  def upsert_benchmark_rollups(rows) when is_list(rows) do
    now = DateTime.utc_now()

    entries = Enum.map(rows, &benchmark_rollup_entry(&1, now))

    Repo.insert_all(Rollup, entries,
      conflict_target: [:metric_key, :bucket_start, :bucket_size, :source, :dimension_key],
      on_conflict: {:replace_all_except, [:id, :inserted_at]}
    )
  end

  @doc "Returns telemetry feature flag state."
  @spec telemetry_enabled?() :: boolean()
  def telemetry_enabled?, do: to_bool(System.get_config("telemetry.enabled"), true)

  @doc "Returns benchmark sync opt-in state."
  @spec benchmark_opt_in?() :: boolean()
  def benchmark_opt_in?, do: to_bool(System.get_config("telemetry.benchmark_opt_in"), false)

  @doc "Returns whether infrastructure telemetry collection is enabled."
  @spec capture_infra_metrics?() :: boolean()
  def capture_infra_metrics?,
    do: to_bool(System.get_config("telemetry.capture_infra_metrics"), false)

  @doc "Returns minimum Phoenix request duration in milliseconds for collection."
  @spec request_duration_threshold_ms() :: non_neg_integer()
  def request_duration_threshold_ms,
    do: System.get_telemetry_config().request_duration_threshold_ms

  @doc "Returns minimum Repo query duration in milliseconds for collection."
  @spec repo_query_duration_threshold_ms() :: non_neg_integer()
  def repo_query_duration_threshold_ms,
    do: System.get_telemetry_config().repo_query_duration_threshold_ms

  @doc "Returns no-answer alert threshold percentage for conversations dashboards."
  @spec no_answer_alert_threshold_percent() :: non_neg_integer()
  def no_answer_alert_threshold_percent,
    do: System.get_telemetry_config().no_answer_alert_threshold_percent

  @doc "Returns response SLA in milliseconds for conversations dashboards."
  @spec conversation_response_sla_ms() :: non_neg_integer()
  def conversation_response_sla_ms,
    do: System.get_telemetry_config().conversation_response_sla_ms

  @doc "Returns the configured remote telemetry endpoint URL."
  @spec remote_url() :: String.t()
  def remote_url do
    System.get_config("telemetry.remote_url") || Elixir.System.get_env("TELEMETRY_REMOTE_URL") ||
      @default_remote_url
  end

  @doc "Returns the remote telemetry API token."
  @spec remote_token() :: String.t()
  def remote_token do
    Elixir.System.get_env("TELEMETRY_REMOTE_TOKEN") || System.get_config("telemetry.remote_token") ||
      ""
  end

  @doc "Returns additional Req options configured for remote connector tests."
  @spec req_options() :: keyword()
  def req_options do
    :zaq
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_options, [])
  end

  @doc "Builds a deterministic key from dimensions."
  @spec dimension_key(map()) :: String.t()
  def dimension_key(dimensions) when map_size(dimensions) == 0, do: "global"

  def dimension_key(dimensions) do
    dimensions
    |> normalize_dimensions()
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map_join("|", fn {k, v} -> "#{k}=#{v}" end)
  end

  @doc "Reads telemetry cursor from system configs."
  @spec get_cursor(String.t()) :: DateTime.t() | nil
  def get_cursor(name) do
    name
    |> System.get_config()
    |> parse_datetime()
  end

  @doc "Persists telemetry cursor in system configs."
  @spec put_cursor(String.t(), DateTime.t()) :: {:ok, term()} | {:error, term()}
  def put_cursor(name, %DateTime{} = cursor) do
    System.set_config(name, DateTime.to_iso8601(cursor))
  end

  @doc "Reads telemetry integer cursor from system configs."
  @spec get_cursor_id(String.t()) :: non_neg_integer()
  def get_cursor_id(name) do
    name
    |> System.get_config()
    |> parse_int(0)
  end

  @doc "Persists telemetry integer cursor in system configs."
  @spec put_cursor_id(String.t(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def put_cursor_id(name, cursor_id) when is_integer(cursor_id) and cursor_id >= 0 do
    System.set_config(name, Integer.to_string(cursor_id))
  end

  @doc "Returns profile dimensions used for benchmark cohorting."
  @spec organization_profile() :: map()
  def organization_profile do
    %{
      org_id: System.get_config("telemetry.org_id"),
      size: System.get_config("telemetry.org_size") || "unknown",
      geography: System.get_config("telemetry.geography") || "unknown",
      industry: System.get_config("telemetry.industry") || "unknown"
    }
  end

  defp range_for_days(days) when days <= 1, do: "24h"
  defp range_for_days(days) when days <= 7, do: "7d"
  defp range_for_days(days) when days <= 30, do: "30d"
  defp range_for_days(_days), do: "90d"

  defp metric_value(metrics, metric_id, default) do
    case Enum.find(metrics, &(&1.id == metric_id)) do
      %{value: value} when is_number(value) -> value * 1.0
      _ -> default
    end
  end

  defp benchmark_rollup_entry(row, now) do
    dimensions = row_value(row, "dimensions", %{})

    %{
      metric_key: row_value(row, "metric_key", nil),
      bucket_start: parse_datetime(row_value(row, "bucket_start", nil)),
      bucket_size: row_value(row, "bucket_size", @bucket_size),
      source: "benchmark",
      dimensions: dimensions,
      dimension_key: dimension_key(dimensions),
      value_sum: to_float(row_value(row, "value_sum", 0)),
      value_count: to_integer(row_value(row, "value_count", 0)),
      value_min: to_float(row_value(row, "value_min", 0)),
      value_max: to_float(row_value(row, "value_max", 0)),
      last_value: to_float(row_value(row, "last_value", 0)),
      last_at: parse_datetime(row_value(row, "last_at", nil)) || now,
      inserted_at: now,
      updated_at: now
    }
  end

  defp row_value(row, key, default) when is_binary(key) do
    case Map.fetch(row, key) do
      {:ok, value} ->
        value

      :error ->
        case row_existing_atom_key(row, key) do
          nil -> default
          atom -> Map.get(row, atom, default)
        end
    end
  end

  defp row_existing_atom_key(row, key) do
    Enum.find(Map.keys(row), fn
      atom when is_atom(atom) -> Atom.to_string(atom) == key
      _other -> false
    end)
  end

  defp normalize_dimensions(dimensions) when is_map(dimensions) do
    dimensions
    |> Enum.reduce(%{}, fn {k, v}, acc -> Map.put(acc, to_string(k), normalize_dim_value(v)) end)
  end

  defp normalize_dimensions(_), do: %{}

  defp normalize_occurred_at(%DateTime{} = occurred_at), do: occurred_at
  defp normalize_occurred_at(_), do: DateTime.utc_now()

  defp normalize_dim_value(value) when is_binary(value), do: value
  defp normalize_dim_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_dim_value(value) when is_boolean(value), do: to_string(value)
  defp normalize_dim_value(value) when is_integer(value) or is_float(value), do: value
  defp normalize_dim_value(value), do: inspect(value)

  defp persist_metric?(metric_key, opts) do
    cond do
      has_prefix?(metric_key, @business_metric_prefixes) -> true
      has_prefix?(metric_key, @infra_metric_prefixes) -> Keyword.get(opts, :allow_infra, false)
      true -> false
    end
  end

  defp has_prefix?(metric_key, prefixes) do
    Enum.any?(prefixes, &String.starts_with?(metric_key, &1))
  end

  defp to_bool(nil, default), do: default
  defp to_bool(value, _default) when value in [true, "true", "1", 1], do: true
  defp to_bool(_value, _default), do: false

  defp parse_datetime(nil), do: nil

  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_float(value), do: trunc(value)

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> 0
    end
  end

  defp to_integer(_), do: 0

  defp normalize_days(days) when is_integer(days) and days > 0, do: days

  defp normalize_days(params) when is_map(params) do
    params
    |> Map.get(:days)
    |> normalize_days()
  end

  defp normalize_days(params) when is_list(params) do
    params
    |> Keyword.get(:days)
    |> normalize_days()
  end

  defp normalize_days(_), do: 30
end
