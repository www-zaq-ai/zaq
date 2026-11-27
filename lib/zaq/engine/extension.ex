defmodule Zaq.Engine.Extension do
  @moduledoc """
  Engine-owned authenticated Extension stream and cached gateway liveness.

  A supervised reader performs blocking stream reads; bounded background writes
  keep snapshot reads independent of transport stalls. Health requires a recent,
  correlated gateway response on this stream, not merely an open TLS connection.
  Disconnects discard transient correlation; reconnect never replays operations.
  """

  use GenServer

  alias Zaq.Engine.Extension.{
    ActionProtocol,
    ActionSession,
    Client,
    Health,
    Protocol,
    Reader,
    Writer
  }

  alias Zaq.Engine.Extension.Rpc.Gateway.V1.{GatewayEnvelope, HealthResponse}

  @doc "Starts the node-local stream runtime without waiting for the gateway."
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

    poll_interval = Keyword.get(opts, :poll_interval_ms, 30_000)
    retry_interval = Keyword.get(opts, :reconnect_interval_ms, min(poll_interval, 1_000))

    state = %{
      health: health,
      checked_monotonic: nil,
      reader: nil,
      writer: nil,
      writing: false,
      actions:
        ActionSession.new(Keyword.get(opts, :action_supervisor, __MODULE__.ActionSupervisor)),
      probe_due: false,
      cleanup: nil,
      connection_name: nil,
      generation: nil,
      hello_id: nil,
      pending: nil,
      first_probe: true,
      started_at: nil,
      deadline: nil,
      scheduled: nil,
      phase: :disconnected,
      max_envelope_bytes: Protocol.max_envelope_bytes(),
      opts: opts,
      poll_interval_ms: poll_interval,
      probe_timeout_ms: Keyword.get(opts, :probe_timeout_ms, 5_000),
      stale_after_ms: Keyword.get(opts, :stale_after_ms, 45_000),
      retry_interval_ms: retry_interval,
      retry_delay_ms: retry_interval,
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    }

    if configured?, do: send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    health =
      if state.checked_monotonic &&
           state.clock.() - state.checked_monotonic > state.stale_after_ms do
        %{state.health | status: :unreachable, reason: :stale, response_time_ms: nil}
      else
        state.health
      end

    {:reply, health, state}
  end

  def handle_call(
        {:extension_frame, generation, _frame, _received_at},
        _from,
        %{generation: active} = state
      )
      when generation != active,
      do: {:reply, {:reject, :invalid_envelope}, state}

  def handle_call(
        {:extension_frame, _generation, frame, _received_at},
        _from,
        %{phase: :negotiating} = state
      ) do
    with {:ok, limit} <- Protocol.negotiate(frame, state.hello_id),
         {:hello, hello} <- frame.payload,
         {:ok, action_limits} <- ActionProtocol.negotiate(hello, limit) do
      send(self(), :probe)
      actions = ActionSession.configure(state.actions, action_limits, state.generation)

      {:reply, {:continue, limit},
       %{state | phase: :ready, max_envelope_bytes: limit, actions: actions}}
    else
      {:error, reason} ->
        reject_frame(state, reason)
    end
  end

  def handle_call(
        {:extension_frame, _generation, frame, received_at},
        _from,
        %{phase: :ready} = state
      ) do
    case Protocol.validate(frame) do
      :ok -> receive_frame(frame, received_at, state)
      {:error, reason} -> reject_frame(state, reason)
    end
  end

  def handle_call({:extension_frame, _generation, _frame, _received_at}, _from, state),
    do: {:reply, {:reject, :invalid_envelope}, state}

  def handle_call(
        {:oversized_extension_frame, generation},
        _from,
        %{generation: generation} = state
      )
      when not is_nil(generation),
      do: reject_frame(state, :resource_exhausted)

  def handle_call({:oversized_extension_frame, _generation}, _from, state),
    do: {:reply, {:reject, :resource_exhausted}, state}

  @impl true
  def handle_info(:connect, %{phase: :disconnected} = state) do
    owner = self()
    generation = make_ref()
    name = make_ref()
    hello_id = Ecto.UUID.generate()
    opts = Keyword.put(state.opts, :connection_name, name)
    started_at = state.clock.()

    writer =
      Task.Supervisor.async_nolink(Zaq.TaskSupervisor, fn ->
        Writer.run(owner, generation, hello_id, opts)
      end)

    state = %{
      state
      | writer: writer,
        generation: generation,
        connection_name: name,
        hello_id: hello_id,
        started_at: started_at,
        first_probe: true,
        scheduled: nil,
        max_envelope_bytes: Protocol.max_envelope_bytes(),
        phase: :connecting
    }

    {:noreply, start_deadline(state)}
  end

  def handle_info({:extension_stream, generation, stream}, %{generation: generation} = state) do
    owner = self()
    limit = state.max_envelope_bytes

    reader =
      Task.Supervisor.async_nolink(Zaq.TaskSupervisor, fn ->
        Reader.run(owner, generation, stream, limit)
      end)

    {:noreply, %{state | reader: reader, phase: :negotiating}}
  end

  def handle_info(:probe, %{phase: :ready, pending: nil, writing: false} = state) do
    {:noreply, start_probe(state)}
  end

  def handle_info(:probe, %{phase: :ready, pending: nil, writing: true} = state) do
    state = %{state | probe_due: true, scheduled: nil}
    {:noreply, if(state.deadline, do: state, else: start_deadline(state))}
  end

  def handle_info(:probe, %{phase: :ready} = state) do
    {:noreply, disconnect(state, :timeout)}
  end

  def handle_info({:deadline, token}, %{deadline: {_timer, token}} = state),
    do: {:noreply, disconnect(state, :timeout)}

  def handle_info({ref, {:error, reason}}, %{reader: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, disconnect(%{state | reader: nil}, reason)}
  end

  def handle_info({:extension_sent, generation}, %{generation: generation} = state),
    do: {:noreply, pump_actions(%{state | writing: false})}

  def handle_info({:extension_action_completed, generation, id, outcome}, state) do
    actions = ActionSession.complete(state.actions, generation, id, outcome)
    {:noreply, pump_actions(%{state | actions: actions})}
  end

  def handle_info({:action_deadline, generation, id}, state) do
    actions = ActionSession.deadline(state.actions, generation, id)
    {:noreply, pump_actions(%{state | actions: actions})}
  end

  def handle_info(
        {:action_receipt_deadline, generation, sequence},
        %{generation: generation} = state
      ) do
    if Map.has_key?(state.actions.replies, sequence),
      do: {:noreply, disconnect(state, :timeout)},
      else: {:noreply, state}
  end

  def handle_info({ref, result}, %{writer: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    reason =
      case result do
        {:error, reason} -> reason
        :ok -> :unreachable
      end

    {:noreply, disconnect(%{state | writer: nil}, reason)}
  end

  def handle_info({ref, _result}, %{cleanup: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, schedule_reconnect(%{state | cleanup: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{reader: %Task{ref: ref}} = state),
    do: {:noreply, disconnect(%{state | reader: nil}, :unreachable)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{writer: %Task{ref: ref}} = state),
    do: {:noreply, disconnect(%{state | writer: nil}, :unreachable)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{cleanup: %Task{ref: ref}} = state),
    do: {:noreply, schedule_reconnect(%{state | cleanup: nil})}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{actions: %{workers: workers}} = state)
      when is_map_key(workers, ref) do
    actions = ActionSession.worker_down(state.actions, ref)
    {:noreply, pump_actions(%{state | actions: actions})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_task(state.reader)
    stop_writer(state.writer)
    stop_task(state.cleanup)
    if state.connection_name, do: Client.disconnect(state.connection_name)
    :ok
  end

  defp receive_frame(
         %GatewayEnvelope{
           request_id: id,
           payload: {:health_response, %HealthResponse{} = response}
         },
         _received_at,
         %{pending: %{id: id} = pending} = state
       ) do
    result = if response.status == "ok", do: {:ok, :healthy}, else: {:error, :unexpected_status}
    elapsed = max(state.clock.() - pending.started_at, 0)

    state =
      state
      |> cancel_deadline()
      |> put_health(result, elapsed)
      |> Map.merge(%{pending: nil, first_probe: false, retry_delay_ms: state.retry_interval_ms})

    timer = Process.send_after(self(), :probe, state.poll_interval_ms)
    {:reply, :continue, %{state | scheduled: timer}}
  end

  defp receive_frame(
         %GatewayEnvelope{request_id: id, payload: {:action_request, request}},
         received_at,
         state
       ) do
    case ActionSession.request(state.actions, id, request, received_at) do
      {:ok, actions} -> {:reply, :continue, pump_actions(%{state | actions: actions})}
      {:error, reason, actions} -> reject_frame(%{state | actions: actions}, reason)
    end
  end

  defp receive_frame(
         %GatewayEnvelope{request_id: id, payload: {:action_receipt, receipt}},
         _received_at,
         state
       ) do
    case ActionSession.receipt(state.actions, id, receipt.sequence) do
      {:ok, actions} -> {:reply, :continue, %{state | actions: actions}}
      {:error, reason, actions} -> reject_frame(%{state | actions: actions}, reason)
    end
  end

  defp receive_frame(%GatewayEnvelope{payload: {:health_response, _}}, _received_at, state),
    do: {:reply, :continue, state}

  defp receive_frame(%GatewayEnvelope{payload: {:error, _}}, _received_at, state),
    do: reject_frame(state, :rpc_error)

  defp receive_frame(_frame, _received_at, state), do: reject_frame(state, :unsupported_operation)

  defp pump_actions(%{phase: :ready, writing: false, probe_due: true} = state) do
    start_probe(state)
  end

  defp pump_actions(%{phase: :ready, writing: false} = state) do
    case ActionSession.take_next(state.actions) do
      {nil, _actions} ->
        state

      {{_sequence, frame}, actions} ->
        send(state.writer.pid, {:write, frame})
        %{state | actions: actions, writing: true}
    end
  end

  defp pump_actions(state), do: state

  defp start_probe(state) do
    pending = %{
      id: Ecto.UUID.generate(),
      started_at: if(state.first_probe, do: state.started_at, else: state.clock.())
    }

    send(state.writer.pid, {:write, Protocol.health_request(pending.id)})
    state = %{state | pending: pending, writing: true, scheduled: nil, probe_due: false}
    if state.deadline, do: state, else: start_deadline(state)
  end

  defp reject_frame(state, reason) do
    if state.scheduled, do: Process.cancel_timer(state.scheduled)

    state =
      state
      |> put_health({:error, reason})
      |> Map.merge(%{phase: :rejecting, scheduled: nil})

    state = if state.deadline, do: state, else: start_deadline(state)
    {:reply, {:reject, reason}, state}
  end

  defp start_deadline(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:deadline, token}, state.probe_timeout_ms)
    %{state | deadline: {timer, token}}
  end

  defp cancel_deadline(state) do
    if state.deadline, do: Process.cancel_timer(elem(state.deadline, 0))
    %{state | deadline: nil}
  end

  defp disconnect(state, reason) do
    stop_task(state.reader)
    stop_writer(state.writer)
    if state.scheduled, do: Process.cancel_timer(state.scheduled)
    name = state.connection_name
    cleanup = Task.Supervisor.async_nolink(Zaq.TaskSupervisor, fn -> Client.disconnect(name) end)

    state
    |> cancel_deadline()
    |> put_health({:error, reason})
    |> Map.merge(%{
      reader: nil,
      writer: nil,
      writing: false,
      probe_due: false,
      actions: ActionSession.configure(state.actions, nil, nil),
      cleanup: cleanup,
      generation: nil,
      pending: nil,
      phase: :cleanup,
      scheduled: nil
    })
  end

  defp schedule_reconnect(state) do
    timer = Process.send_after(self(), :connect, state.retry_delay_ms)

    %{
      state
      | phase: :disconnected,
        connection_name: nil,
        scheduled: timer,
        retry_delay_ms: min(state.retry_delay_ms * 2, 30_000)
    }
  end

  defp stop_task(nil), do: :ok
  defp stop_task(task), do: Task.shutdown(task, :brutal_kill)

  defp stop_writer(nil), do: :ok
  defp stop_writer(task), do: send(task.pid, :stop)

  defp put_health(state, result, response_time_ms \\ nil) do
    {status, reason} =
      case result do
        {:ok, :healthy} -> {:healthy, nil}
        {:error, reason} when reason in [:unreachable, :timeout] -> {:unreachable, reason}
        {:error, reason} -> {:error, reason}
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
