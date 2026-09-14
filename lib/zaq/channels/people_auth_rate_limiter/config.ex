defmodule Zaq.Channels.PeopleAuthRateLimiter.Config do
  @moduledoc """
  Channels-local read-only snapshot of the typed People access configuration.

  Refreshes through the existing Engine config action at startup and every 30 seconds
  after completion. Requests read ETS without waiting for Engine or querying Repo.
  Snapshots expire 120 seconds after refresh starts, bounding stale use even while
  a refresh is stuck. Any failed/invalid refresh removes the snapshot immediately.
  Cache restarts do not reset rate counters. No authentication data is dispatched.
  """
  use GenServer

  alias Zaq.Engine.Events
  alias Zaq.System.PeopleAccessConfig

  @refresh_ms 30_000
  @max_age_ms 120_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns only a fresh local snapshot; never fetches on the caller's path."
  @spec get() :: {:ok, PeopleAccessConfig.t()} | {:error, :rate_limiter_unavailable}
  def get do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(__MODULE__, :config) do
      [{:config, config, expires}] when expires > now -> {:ok, config}
      _ -> {:error, :rate_limiter_unavailable}
    end
  rescue
    ArgumentError -> {:error, :rate_limiter_unavailable}
  end

  @impl true
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, nil, {:continue, :refresh}}
  end

  @impl true
  def handle_continue(:refresh, state), do: handle_info(:refresh, state)

  @impl true
  def handle_info(:refresh, timer) do
    if timer, do: Process.cancel_timer(timer)
    expires = System.monotonic_time(:millisecond) + @max_age_ms

    case fetch() do
      {:ok, config} -> :ets.insert(__MODULE__, {:config, config, expires})
      :unavailable -> :ets.delete(__MODULE__, :config)
    end

    {:noreply, Process.send_after(self(), :refresh, @refresh_ms)}
  end

  defp fetch do
    case Events.build_and_dispatch_invoke_event(%{}, :system_config_get_people_access_config).response do
      {:ok, %PeopleAccessConfig{} = config} -> {:ok, config}
      _ -> :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end
end
