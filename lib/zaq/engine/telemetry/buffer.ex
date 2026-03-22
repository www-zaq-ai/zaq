defmodule Zaq.Engine.Telemetry.Buffer do
  @moduledoc """
  In-memory telemetry point buffer.

  Telemetry handlers cast points into this process to avoid blocking the caller.
  Points are periodically flushed with `insert_all/3` for write efficiency.

  On graceful shutdown, `terminate/2` performs a best-effort final flush so
  in-flight buffered points are persisted before exit.
  """

  use GenServer
  require Logger

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Point
  alias Zaq.Repo

  @default_flush_interval_ms 10_000
  @default_max_batch_size 200

  @type point_input :: %{
          required(:metric_key) => String.t(),
          required(:value) => number(),
          optional(:occurred_at) => DateTime.t(),
          optional(:dimensions) => map(),
          optional(:source) => String.t(),
          optional(:node) => String.t()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Queues one telemetry point for asynchronous persistence."
  @spec enqueue(point_input()) :: :ok
  @spec enqueue(GenServer.server(), point_input()) :: :ok
  def enqueue(server \\ __MODULE__, point)

  def enqueue(server, point) when is_map(point) do
    GenServer.cast(server, {:enqueue, point})
  end

  @doc "Forces an immediate flush of buffered points."
  @spec flush() :: :ok | {:error, term()}
  @spec flush(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__, timeout \\ 1_500) do
    GenServer.call(server, :flush, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :noproc}
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(opts) do
    state = %{
      points: [],
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @default_flush_interval_ms),
      max_batch_size: Keyword.get(opts, :max_batch_size, @default_max_batch_size)
    }

    {:ok, schedule_flush(state)}
  end

  @impl true
  def handle_cast({:enqueue, point}, state) do
    new_state = %{state | points: [normalize_point(point) | state.points]}

    if length(new_state.points) >= state.max_batch_size do
      {:noreply, flush_points(new_state)}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, flush_points(state)}
  end

  @impl true
  def handle_info(:flush, state) do
    {:noreply, state |> flush_points() |> schedule_flush()}
  end

  @impl true
  def terminate(reason, state) do
    _ = safe_terminate_flush(reason, state)
    :ok
  end

  defp normalize_point(point) do
    metric_key = Map.fetch!(point, :metric_key)
    value = Map.fetch!(point, :value)
    dimensions = Map.get(point, :dimensions, %{})
    occurred_at = Map.get(point, :occurred_at, DateTime.utc_now())

    %{
      metric_key: metric_key,
      value: value * 1.0,
      dimensions: dimensions,
      dimension_key: Telemetry.dimension_key(dimensions),
      occurred_at: occurred_at,
      source: Map.get(point, :source, "local"),
      node: Map.get(point, :node, Atom.to_string(node())),
      inserted_at: DateTime.utc_now()
    }
  end

  defp flush_points(%{points: []} = state), do: state

  defp flush_points(%{points: points} = state) do
    entries = Enum.reverse(points)

    try do
      {inserted_count, _} = Repo.insert_all(Point, entries, on_conflict: :nothing)

      if inserted_count < length(entries) do
        Logger.warning(
          "[Telemetry.Buffer] insert_all inserted #{inserted_count}/#{length(entries)} points (on_conflict: :nothing)"
        )
      end

      %{state | points: []}
    rescue
      error ->
        Logger.error(
          "[Telemetry.Buffer] Failed to flush #{length(entries)} points: #{Exception.message(error)}"
        )

        state
    end
  end

  defp safe_terminate_flush(reason, state) do
    flush_points(state)
  rescue
    error ->
      Logger.warning(
        "[Telemetry.Buffer] Final shutdown flush failed (#{inspect(reason)}): #{Exception.message(error)}"
      )

      state
  end

  defp schedule_flush(state) do
    Process.send_after(self(), :flush, state.flush_interval_ms)
    state
  end
end
