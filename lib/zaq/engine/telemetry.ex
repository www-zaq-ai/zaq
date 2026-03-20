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
  """

  import Ecto.Query

  alias Zaq.Engine.Telemetry.{Buffer, DashboardData, Rollup}
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
        occurred_at: DateTime.utc_now(),
        source: "local"
      })
    else
      :ok
    end
  end

  @doc "Records user feedback telemetry based on a rating value."
  @spec record_feedback(integer(), map()) :: :ok
  def record_feedback(rating, dimensions \\ %{}) do
    base = normalize_dimensions(dimensions)

    record("feedback.rating", rating, base)

    if rating <= 2 do
      record("feedback.negative.count", 1, base)
    end

    :ok
  end

  @doc "Returns a standardized dashboard payload for the provided filters."
  @spec load_dashboard(map()) :: map()
  def load_dashboard(filters), do: DashboardData.load_dashboard(filters)

  @doc "Returns one chart payload by its identifier."
  @spec load_chart(String.t(), map()) :: {:ok, map()} | {:error, :unknown_chart}
  def load_chart(chart_id, filters), do: DashboardData.load_chart(chart_id, filters)

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

    entries =
      Enum.map(rows, fn row ->
        %{
          metric_key: row["metric_key"] || row[:metric_key],
          bucket_start: parse_datetime(row["bucket_start"] || row[:bucket_start]),
          bucket_size: row["bucket_size"] || row[:bucket_size] || @bucket_size,
          source: "benchmark",
          dimensions: row["dimensions"] || row[:dimensions] || %{},
          dimension_key: dimension_key(row["dimensions"] || row[:dimensions] || %{}),
          value_sum: to_float(row["value_sum"] || row[:value_sum] || 0),
          value_count: to_integer(row["value_count"] || row[:value_count] || 0),
          value_min: to_float(row["value_min"] || row[:value_min] || 0),
          value_max: to_float(row["value_max"] || row[:value_max] || 0),
          last_value: to_float(row["last_value"] || row[:last_value] || 0),
          last_at: parse_datetime(row["last_at"] || row[:last_at]) || now,
          inserted_at: now,
          updated_at: now
        }
      end)

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

  defp normalize_dimensions(dimensions) when is_map(dimensions) do
    dimensions
    |> Enum.reduce(%{}, fn {k, v}, acc -> Map.put(acc, to_string(k), normalize_dim_value(v)) end)
  end

  defp normalize_dimensions(_), do: %{}

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
end
