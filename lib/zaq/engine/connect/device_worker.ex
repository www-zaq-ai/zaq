defmodule Zaq.Engine.Connect.DeviceWorker do
  @moduledoc """
  Temporary Connect device orchestrator. Holds only an attempt ID and trusted opts;
  provider interpretation supplies timing through DeviceAttempts. Never restarts,
  recovers or logs provider material. A browser disconnect does not end this process.
  """
  use GenServer, restart: :temporary
  alias Zaq.Engine.Connect.DeviceAttempts
  alias Zaq.Utils.DateUtils

  def start_link({id, opts}), do: GenServer.start_link(__MODULE__, {id, opts})

  @impl true
  def init({id, opts}) do
    case DeviceAttempts.attach_worker(id, self(), opts) do
      {:ok, attempt} ->
        schedule(attempt, opts)
        {:ok, %{id: id, opts: opts}}

      _ ->
        {:stop, :normal}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case DeviceAttempts.poll(state.id, self(), state.opts) do
      {:ok, %{status: "pending"} = attempt} ->
        schedule(attempt, state.opts)
        {:noreply, state}

      _ ->
        {:stop, :normal, state}
    end
  end

  defp schedule(attempt, opts) do
    remaining = max(DateTime.diff(attempt.expires_at, DateUtils.now(opts), :millisecond), 0)
    Process.send_after(self(), :poll, min(attempt.interval * 1_000, remaining))
  end
end
