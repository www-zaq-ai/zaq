defmodule Zaq.Engine.Extension.ActionWorkers do
  @moduledoc """
  Tracks live Extension invocation IDs independently of the stream runtime.

  Starting and recording a worker are serialized here, so a runtime restart
  cannot leave a running invocation untracked. The tracker and task pool restart
  together; a tracker restart cannot lose the IDs of surviving workers.
  """

  use GenServer

  alias Zaq.{Event, NodeRouter}

  @task_supervisor Zaq.Engine.Extension.ActionSupervisor

  @doc false
  def start_pool_link do
    Supervisor.start_link(
      [{Task.Supervisor, name: @task_supervisor}, __MODULE__],
      strategy: :one_for_all
    )
  end

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Checks whether an invocation with this ID is still running in the given pool."
  @spec active?(Supervisor.supervisor(), String.t()) :: boolean()
  def active?(supervisor, id), do: GenServer.call(__MODULE__, {:active?, {supervisor, id}})

  @doc "Starts a tracked Engine hop if the ID is free and its deadline has not passed."
  @spec dispatch(Supervisor.supervisor(), Event.t(), integer()) ::
          {:ok, pid()} | {:error, :invalid_envelope | :deadline_exceeded | :unavailable}
  def dispatch(supervisor, %Event{} = event, expires_at),
    do: GenServer.call(__MODULE__, {:dispatch, supervisor, event, expires_at})

  @impl true
  def init(workers), do: {:ok, workers}

  @impl true
  def handle_call({:active?, key}, _from, workers),
    do: {:reply, active_worker?(workers, key), workers}

  def handle_call({:dispatch, supervisor, event, expires_at}, {owner, _tag}, workers) do
    key = {supervisor, event.trace_id}

    cond do
      active_worker?(workers, key) ->
        {:reply, {:error, :invalid_envelope}, workers}

      not Process.alive?(owner) ->
        {:reply, {:error, :unavailable}, workers}

      System.monotonic_time(:millisecond) >= expires_at ->
        {:reply, {:error, :deadline_exceeded}, workers}

      true ->
        case NodeRouter.dispatch(event, %{async_task_supervisor: supervisor}) do
          %Event{assigns: %{async_task_pid: pid}} when is_pid(pid) ->
            {:reply, {:ok, pid}, Map.put(workers, Process.monitor(pid), {key, pid})}

          _ ->
            {:reply, {:error, :unavailable}, workers}
        end
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, workers),
    do: {:noreply, Map.delete(workers, ref)}

  defp active_worker?(workers, key) do
    Enum.any?(workers, fn {_ref, {worker_key, pid}} ->
      worker_key == key and Process.alive?(pid)
    end)
  end
end
