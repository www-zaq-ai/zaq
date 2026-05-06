defmodule Zaq.Agent.IdleLifecycle do
  @moduledoc false

  @behaviour Jido.AgentServer.Lifecycle

  @impl true
  def init(_opts, state), do: start_timer(state)

  @impl true
  def handle_event(:idle_timeout, state) do
    server_id = state.id
    send(Zaq.Agent.ServerManager, {:expire_server, server_id})
    {:cont, state}
  end

  def handle_event(:touch, state), do: {:cont, state |> cancel_timer() |> start_timer()}
  def handle_event(_event, state), do: {:cont, state}

  @impl true
  def persist_cron_specs(_state, _cron_specs), do: :ok

  @impl true
  def terminate(_reason, _state), do: :ok

  defp start_timer(state) do
    timeout = state.lifecycle.idle_timeout

    if is_integer(timeout) and timeout > 0 do
      ref = :erlang.start_timer(timeout, self(), :lifecycle_idle_timeout)
      %{state | lifecycle: %{state.lifecycle | idle_timer: ref}}
    else
      state
    end
  end

  defp cancel_timer(state) do
    case state.lifecycle.idle_timer do
      nil ->
        state

      ref ->
        :erlang.cancel_timer(ref)
        %{state | lifecycle: %{state.lifecycle | idle_timer: nil}}
    end
  end
end
