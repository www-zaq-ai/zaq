defmodule Zaq.Engine.Telemetry.Collector do
  @moduledoc """
  Runtime telemetry collector for native Phoenix, Ecto, and Oban events.

  Collected events are normalized into metric points and forwarded to
  `Zaq.Engine.Telemetry.record/4`.
  """

  use GenServer

  alias Zaq.Engine.Telemetry
  alias Zaq.System, as: SystemConfig

  @handler_id "zaq-engine-telemetry-collector"
  @policy_key {__MODULE__, :policy}

  @default_policy %{
    capture_infra_metrics: false,
    request_duration_threshold_ms: 10,
    repo_query_duration_threshold_ms: 5
  }

  @events [
    [:phoenix, :router_dispatch, :stop],
    [:phoenix, :router_dispatch, :exception],
    [:zaq, :repo, :query],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]
  @noisy_route_prefixes ["/assets", "/images", "/fonts"]
  @noisy_routes ["/favicon.ico", "/robots.txt", "/health", "/healthz", "/up", "/status"]
  @repo_noise_sources ["telemetry_points", "telemetry_rollups", "system_configs"]

  @doc "Reloads collector policy from persisted telemetry settings."
  @spec reload_policy() :: :ok
  def reload_policy do
    GenServer.cast(__MODULE__, :reload_policy)
  end

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    load_and_store_policy()
    :ok = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})
    {:ok, state}
  end

  @impl true
  def handle_cast(:reload_policy, state) do
    load_and_store_policy()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :persistent_term.erase(@policy_key)
    :ok
  end

  @doc false
  def handle_event([:phoenix, :router_dispatch, :stop], measures, metadata, _config) do
    policy = current_policy()
    route = to_string(metadata.route || "unknown")
    duration_ms = native_ms(measures.duration)

    if capture_infra?(policy) and
         not noisy_route?(route) and
         duration_ms >= policy.request_duration_threshold_ms do
      Telemetry.record(
        "phoenix.request.duration_ms",
        duration_ms,
        %{route: route},
        allow_infra: true
      )
    else
      :ok
    end
  end

  def handle_event([:phoenix, :router_dispatch, :exception], measures, metadata, _config) do
    policy = current_policy()
    route = to_string(metadata.route || "unknown")
    duration_ms = native_ms(measures.duration)

    if capture_infra?(policy) and
         not noisy_route?(route) and
         duration_ms >= policy.request_duration_threshold_ms do
      Telemetry.record(
        "phoenix.request.exception_ms",
        duration_ms,
        %{route: route},
        allow_infra: true
      )
    else
      :ok
    end
  end

  def handle_event([:zaq, :repo, :query], measures, metadata, _config) do
    policy = current_policy()
    source = to_string(metadata.source || "unknown")
    duration_ms = native_ms(measures.total_time)

    if capture_infra?(policy) and
         record_repo_query?(source, duration_ms) and
         duration_ms >= policy.repo_query_duration_threshold_ms do
      Telemetry.record(
        "repo.query.duration_ms",
        duration_ms,
        %{source: source},
        allow_infra: true
      )
    else
      :ok
    end
  end

  def handle_event([:oban, :job, :stop], measures, metadata, _config) do
    if capture_infra?(current_policy()) do
      Telemetry.record(
        "oban.job.duration_ms",
        native_ms(measures.duration),
        %{
          queue: metadata.job.queue,
          worker: metadata.job.worker,
          state: to_string(metadata.state)
        },
        allow_infra: true
      )
    else
      :ok
    end
  end

  def handle_event([:oban, :job, :exception], _measures, metadata, _config) do
    if capture_infra?(current_policy()) do
      Telemetry.record(
        "oban.job.exception.count",
        1,
        %{
          queue: metadata.job.queue,
          worker: metadata.job.worker,
          state: to_string(metadata.state)
        },
        allow_infra: true
      )
    else
      :ok
    end
  end

  def handle_event(_event, _measures, _metadata, _config), do: :ok

  defp native_ms(value) when is_integer(value),
    do: System.convert_time_unit(value, :native, :millisecond)

  defp native_ms(value) when is_float(value), do: value
  defp native_ms(_), do: 0

  defp noisy_route?(route) do
    route in @noisy_routes or Enum.any?(@noisy_route_prefixes, &String.starts_with?(route, &1))
  end

  defp record_repo_query?(source, duration_ms) do
    source not in ["unknown" | @repo_noise_sources] and duration_ms > 0
  end

  defp capture_infra?(%{capture_infra_metrics: value}), do: value

  defp current_policy do
    :persistent_term.get(@policy_key, @default_policy)
  end

  defp load_and_store_policy do
    config = SystemConfig.get_telemetry_config()

    :persistent_term.put(@policy_key, %{
      capture_infra_metrics: config.capture_infra_metrics,
      request_duration_threshold_ms: config.request_duration_threshold_ms,
      repo_query_duration_threshold_ms: config.repo_query_duration_threshold_ms
    })
  rescue
    _ -> :persistent_term.put(@policy_key, @default_policy)
  end
end
