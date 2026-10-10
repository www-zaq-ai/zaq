defmodule ZaqWeb.Live.DeviceSignInPolling do
  @moduledoc """
  One device-sign-in observation timer per LiveView. Reopening the same attempt
  preserves its timer; switching or stopping cancels it. A fresh generation for
  each tick rejects messages already queued before cancellation or consumption.
  Only observation identity lives here, never provider instructions or domain IO.
  """
  alias Phoenix.LiveView
  alias ZaqWeb.Components.DesignSystem.DeviceSignIn

  @doc "Observes an in-progress attempt idempotently, or stops observing a terminal/missing attempt."
  def schedule(socket, attempt, event) do
    if DeviceSignIn.in_progress?(attempt) do
      schedule_attempt(socket, attempt.attempt_id, event)
    else
      stop(socket)
    end
  end

  @doc "Consumes exactly one matching tick before its caller fetches status and schedules a successor."
  def consume(socket, id, generation) do
    case socket.private[:device_sign_in_polling] do
      %{attempt_id: ^id, generation: ^generation} -> {:ok, stop(socket)}
      _ -> :stale
    end
  end

  defp schedule_attempt(socket, id, event) do
    case socket.private[:device_sign_in_polling] do
      %{attempt_id: ^id} -> socket
      _ -> start_timer(stop(socket), id, event)
    end
  end

  defp start_timer(socket, id, event) do
    generation = make_ref()
    timer = Process.send_after(self(), {event, id, generation}, 1_000)

    LiveView.put_private(socket, :device_sign_in_polling, %{
      attempt_id: id,
      generation: generation,
      timer_ref: timer
    })
  end

  defp stop(socket) do
    if timer = socket.private[:device_sign_in_polling], do: Process.cancel_timer(timer.timer_ref)
    LiveView.put_private(socket, :device_sign_in_polling, nil)
  end
end
