defmodule Zaq.E2E.TelemetryFixtures do
  @moduledoc """
  Establishes LLM dashboard fixtures without older telemetry recreating them.

  This is local E2E support: callers must finish telemetry-producing work before
  resetting. Unrelated metrics and the queue's configured pause state are retained.
  """

  import Ecto.Query, only: [from: 2]

  alias Zaq.Engine.Telemetry.{Buffer, Point, Rollup}
  alias Zaq.Repo

  @timeout 15_000

  @doc "Clears LLM telemetry and runs the seed callback atomically, with aggregation quiesced."
  def reset_llm_performance!(seed, opts \\ []) do
    oban = Keyword.get(opts, :oban, Oban)
    buffer = Keyword.get(opts, :buffer, Buffer)

    with_quiesced_queue(oban, fn ->
      flush!(buffer)

      {:ok, result} =
        Repo.transaction(fn ->
          clear_llm_metrics()
          seed.()
        end)

      result
    end)
  end

  defp clear_llm_metrics do
    for schema <- [Point, Rollup] do
      Repo.delete_all(
        from row in schema,
          where: like(row.metric_key, "qa.llm.%") or like(row.metric_key, "qa.tokens.%")
      )
    end
  end

  defp with_quiesced_queue(oban, fun) do
    case Oban.Registry.whereis(oban, {:producer, "telemetry"}) do
      nil ->
        # Normal ExUnit runs use Oban's manual mode and have no queue producer.
        fun.()

      producer ->
        # Oban.pause_queue/2 only sends an asynchronous notification. Suspending
        # the local producer gives a synchronous dispatch barrier without changing
        # its pause setting. Existing jobs continue and must finish before clearing.
        :ok = :sys.suspend(producer, @timeout)

        try do
          oban
          |> Oban.Registry.whereis({:foreman, "telemetry"})
          |> Task.Supervisor.children()
          |> await_jobs!()

          fun.()
        after
          :ok = :sys.resume(producer, @timeout)
        end
    end
  end

  defp await_jobs!(pids) do
    refs = Enum.map(pids, &Process.monitor/1)
    deadline = System.monotonic_time(:millisecond) + @timeout

    try do
      Enum.each(refs, fn ref ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          remaining -> raise "E2E telemetry aggregation did not finish before reset"
        end
      end)
    after
      Enum.each(refs, &Process.demonitor(&1, [:flush]))
    end
  end

  defp flush!(buffer) do
    :ok = Buffer.flush(buffer, @timeout)

    # Buffer currently replies :ok even when insertion fails and it retains points.
    # Inspecting its state is confined to test support; don't accept a partial reset.
    case :sys.get_state(buffer, @timeout) do
      %{points: []} -> :ok
      %{points: points} -> raise "E2E telemetry flush retained #{length(points)} points"
    end
  end
end
