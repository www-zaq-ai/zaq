defmodule Zaq.Channels.HttpClient.Pool do
  @moduledoc """
  Bounds outbound HTTP attempts with supervised request-worker leases.

  Each lease names one immutable worker PID. A runtime restart destroys that worker
  and its sockets; a replacement cannot adopt its request or TLS configuration.
  Acquisition and establishment share an absolute deadline. Saturation fails closed.
  """

  use GenServer

  @capacity 64

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Runs one attempt in a private worker, releasing it even after an exception."
  @spec with_pool(String.t(), keyword(), (keyword() -> term()), GenServer.server()) :: term()
  def with_pool(_url, options, fun, server \\ __MODULE__) do
    lease = make_ref()
    flags = :atomics.new(2, [])
    timeout = get_in(options, [:conn_opts, :transport_opts, :timeout]) || 5_000
    deadline = Keyword.get(options, :deadline, now() + timeout)

    result =
      try do
        case checkout(server, lease, flags, deadline) do
          {:ok, worker} -> execute(worker, lease, flags, deadline, fun)
          {:error, reason} -> {:error, %Req.TransportError{reason: reason}}
        end
      after
        :atomics.put(flags, 2, 1)
        GenServer.cast(server, {:release, lease})
      end

    case result do
      {:raised, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
      other -> other
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       connections: Keyword.fetch!(opts, :connections),
       capacity: Keyword.get(opts, :capacity, @capacity),
       leases: %{}
     }}
  end

  @impl true
  def handle_call({:checkout, owner, lease, flags, deadline}, _from, state) do
    cond do
      expired?(flags, deadline) ->
        {:reply, {:error, :timeout}, state}

      map_size(state.leases) >= state.capacity ->
        {:reply, {:error, :pool_timeout}, state}

      true ->
        start_lease(state, owner, lease, flags, deadline)
    end
  end

  defp start_lease(state, owner, lease, flags, deadline) do
    case Task.Supervisor.start_child(state.connections, fn ->
           await_request(owner, lease, flags, deadline)
         end) do
      {:ok, worker} ->
        entry = %{worker: worker, owner: Process.monitor(owner), monitor: Process.monitor(worker)}
        {:reply, {:ok, worker}, put_in(state.leases[lease], entry)}

      {:error, _} ->
        {:reply, {:error, :closed}, state}
    end
  end

  @impl true
  def handle_cast({:release, lease}, state), do: {:noreply, release(state, lease)}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.leases, fn {_lease, entry} ->
           entry.owner == monitor or entry.monitor == monitor
         end) do
      {lease, _} -> {:noreply, release(state, lease)}
      nil -> {:noreply, state}
    end
  end

  defp checkout(server, lease, flags, deadline) do
    GenServer.call(server, {:checkout, self(), lease, flags, deadline}, max(deadline - now(), 0))
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :closed}
  end

  defp execute(worker, lease, flags, deadline, fun) do
    monitor = Process.monitor(worker)
    send(worker, {:execute, lease, fun})

    try do
      case receive_result(lease, monitor, worker, max(deadline - now(), 0)) do
        :deadline ->
          if :atomics.get(flags, 1) == 1 do
            receive_result(lease, monitor, worker, :infinity)
          else
            :atomics.put(flags, 2, 1)
            {:error, %Req.TransportError{reason: :timeout}}
          end

        result ->
          result
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp receive_result(lease, monitor, worker, timeout) do
    receive do
      {:lease_result, ^lease, result} -> result
      {:DOWN, ^monitor, :process, ^worker, _} -> {:error, %Req.TransportError{reason: :closed}}
    after
      timeout -> :deadline
    end
  end

  defp await_request(owner, lease, flags, deadline) do
    monitor = Process.monitor(owner)

    receive do
      {:execute, ^lease, fun} ->
        result =
          if expired?(flags, deadline) or not Process.alive?(owner) do
            {:error, %Req.TransportError{reason: :timeout}}
          else
            invoke(fun, worker: self(), pool_tag: {:zaq_http, lease, flags}, send_started: flags)
          end

        send(owner, {:lease_result, lease, result})

      {:DOWN, ^monitor, :process, ^owner, _} ->
        :ok
    after
      max(deadline - now(), 0) -> :ok
    end
  end

  defp invoke(fun, options) do
    fun.(options)
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  defp release(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _} ->
        state

      {%{worker: worker, owner: owner, monitor: monitor}, leases} ->
        Process.demonitor(owner, [:flush])
        Process.demonitor(monitor, [:flush])
        Task.Supervisor.terminate_child(state.connections, worker)
        %{state | leases: leases}
    end
  end

  defp expired?(flags, deadline), do: :atomics.get(flags, 2) == 1 or now() >= deadline
  defp now, do: System.monotonic_time(:millisecond)
end
