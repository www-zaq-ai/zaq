defmodule ZaqWeb.Live.DeviceSignInPolling do
  @moduledoc """
  Socket-private observation timers with device-sign-in defaults. Reopening the same attempt
  preserves its timer; switching or stopping cancels it. A fresh generation for
  each tick rejects messages already queued before cancellation or consumption.
  Only observation identity lives here, never provider instructions or domain IO.

  Other observations may supply a private slot, identity, interval and active flag.
  Each slot owns one timer; no timer state is exposed through assigns.
  """
  alias Phoenix.LiveView
  alias ZaqWeb.Components.DesignSystem.DeviceSignIn

  @doc "Observes an in-progress attempt idempotently, or stops observing a terminal/missing attempt."
  def schedule(socket, attempt, event) do
    identity = if is_map(attempt), do: attempt[:attempt_id]

    schedule(
      socket,
      :device_sign_in_polling,
      identity,
      event,
      1_000,
      DeviceSignIn.in_progress?(attempt)
    )
  end

  @doc "Observes an active identity idempotently; changing identity or stopping cancels its timer."
  @spec schedule(LiveView.Socket.t(), atom(), term(), atom(), pos_integer(), boolean()) ::
          LiveView.Socket.t()
  def schedule(socket, key, identity, event, interval_ms, active?) do
    if active? do
      case socket.private[key] do
        %{identity: ^identity, event: ^event, interval_ms: ^interval_ms} -> socket
        _ -> start_timer(stop(socket, key), key, identity, event, interval_ms)
      end
    else
      stop(socket, key)
    end
  end

  @doc "Consumes exactly one matching tick before its caller fetches status and schedules a successor."
  def consume(socket, id, generation) do
    consume(socket, :device_sign_in_polling, id, generation)
  end

  @doc "Consumes exactly one current tick, rejecting duplicates and queued stale messages."
  @spec consume(LiveView.Socket.t(), atom(), term(), reference()) ::
          {:ok, LiveView.Socket.t()} | :stale
  def consume(socket, key, identity, generation) do
    case socket.private[key] do
      %{identity: ^identity, generation: ^generation} -> {:ok, stop(socket, key)}
      _ -> :stale
    end
  end

  @doc "Cancels an observation and clears its private timer metadata."
  @spec stop(LiveView.Socket.t(), atom()) :: LiveView.Socket.t()
  def stop(socket, key \\ :device_sign_in_polling) do
    if timer = socket.private[key], do: Process.cancel_timer(timer.timer_ref)
    LiveView.put_private(socket, key, nil)
  end

  defp start_timer(socket, key, identity, event, interval_ms) do
    generation = make_ref()
    timer = Process.send_after(self(), {event, identity, generation}, interval_ms)

    LiveView.put_private(socket, key, %{
      identity: identity,
      generation: generation,
      timer_ref: timer,
      event: event,
      interval_ms: interval_ms
    })
  end
end
