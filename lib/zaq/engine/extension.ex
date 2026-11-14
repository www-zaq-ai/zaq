defmodule Zaq.Engine.Extension do
  @moduledoc """
  Engine-owned gateway health cache. Only its background task performs local RPCs;
  readers receive a bounded, sanitized connectivity snapshot, never entitlement.
  """

  use GenServer

  alias Zaq.Engine.Extension.{Client, Health}

  @doc "Starts the node-local health runtime without waiting for the gateway."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Reads cached health. A missing or unresponsive Engine runtime is unreachable."
  @spec snapshot(keyword()) :: Health.t()
  def snapshot(opts \\ []) do
    server =
      Keyword.get_lazy(opts, :server, fn ->
        Zaq.Config.get(:zaq, :extension_runtime, __MODULE__, opts)
      end)

    GenServer.call(server, :snapshot, 500)
  catch
    :exit, _ -> %Health{status: :unreachable, reason: :runtime_unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {health, configured?} =
      case Client.settings(opts) do
        {:ok, _} -> {%Health{status: :checking}, true}
        {:error, :unconfigured} -> {%Health{status: :unconfigured}, false}
        {:error, reason} -> {%Health{status: :error, reason: reason}, false}
      end

    state = %{
      health: health,
      checked_monotonic: nil,
      task: nil,
      connection_name: nil,
      deadline_timer: nil,
      phase: :probe,
      opts: opts,
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 30_000),
      probe_timeout_ms: Keyword.get(opts, :probe_timeout_ms, 5_000),
      stale_after_ms: Keyword.get(opts, :stale_after_ms, 45_000),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    }

    if configured?, do: send(self(), :probe)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    health =
      if state.checked_monotonic &&
           state.clock.() - state.checked_monotonic > state.stale_after_ms do
        %{state.health | status: :unreachable, reason: :stale}
      else
        state.health
      end

    {:reply, health, state}
  end

  @impl true
  def handle_info(:probe, %{task: nil} = state) do
    connection_name = make_ref()
    opts = Keyword.put(state.opts, :connection_name, connection_name)
    clock = state.clock

    task =
      Task.Supervisor.async_nolink(Zaq.TaskSupervisor, fn ->
        started_at = clock.()
        result = Client.health(opts)
        {result, clock.() - started_at}
      end)

    timer = Process.send_after(self(), {:probe_timeout, task.ref}, state.probe_timeout_ms)

    {:noreply,
     %{state | task: task, connection_name: connection_name, deadline_timer: timer, phase: :probe}}
  end

  def handle_info(
        {ref, {result, response_time_ms}},
        %{task: %Task{ref: ref}, phase: :probe} = state
      ) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> put_health(result, response_time_ms) |> schedule_probe()}
  end

  def handle_info({ref, _result}, %{task: %Task{ref: ref}, phase: :cleanup} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, schedule_probe(state)}
  end

  def handle_info({:probe_timeout, ref}, %{task: %Task{ref: ref}} = state) do
    Task.shutdown(state.task, :brutal_kill)
    {:noreply, clean_connection(state, :timeout)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{task: %Task{ref: ref}, phase: :probe} = state
      ) do
    {:noreply, clean_connection(state, :probe_failed)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, schedule_probe(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{task: task, connection_name: name}) do
    if task, do: Task.shutdown(task, :brutal_kill)
    if name, do: Client.disconnect(name)
    :ok
  end

  defp clean_connection(state, reason) do
    if state.deadline_timer, do: Process.cancel_timer(state.deadline_timer)
    name = state.connection_name
    task = Task.Supervisor.async_nolink(Zaq.TaskSupervisor, fn -> Client.disconnect(name) end)
    state = put_health(state, {:error, reason})
    %{state | task: task, phase: :cleanup, deadline_timer: nil}
  end

  defp schedule_probe(state) do
    if state.deadline_timer, do: Process.cancel_timer(state.deadline_timer)
    Process.send_after(self(), :probe, state.poll_interval_ms)
    %{state | task: nil, connection_name: nil, deadline_timer: nil}
  end

  defp put_health(state, result, response_time_ms \\ nil) do
    {status, reason} =
      case result do
        {:ok, :healthy} ->
          {:healthy, nil}

        {:error, reason} when reason in [:unreachable, :timeout, :probe_failed] ->
          {:unreachable, reason}

        {:error, reason} ->
          {:error, reason}
      end

    %{
      state
      | health: %Health{
          status: status,
          reason: reason,
          checked_at: DateTime.utc_now(),
          response_time_ms: if(status == :healthy, do: response_time_ms)
        },
        checked_monotonic: state.clock.()
    }
  end
end
