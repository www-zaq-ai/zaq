defmodule Zaq.E2E.TelemetryFixtures do
  @moduledoc """
  Establishes LLM dashboard fixtures without older telemetry recreating them.

  This is local E2E support: callers must finish telemetry-producing work before
  resetting. Unrelated metrics and the queue's configured pause state are retained.
  """

  import Ecto.Query, only: [from: 2]

  alias Zaq.Accounts.People
  alias Zaq.Engine.Telemetry
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

  @doc "Seeds deterministic LLM performance rollups for E2E dashboard rankings."
  def seed_llm_performance_rollups! do
    people =
      [
        "Ada Lovelace",
        "Grace Hopper",
        "Katherine Johnson",
        "Margaret Hamilton",
        "Evelyn Boyd",
        "Mary Jackson"
      ]
      |> Enum.map(fn full_name ->
        {:ok, person} = People.create_person(%{"full_name" => full_name, "incomplete" => false})
        person
      end)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    [
      {"alpha", 1_000.0, 1.0},
      {"bravo", 900.0, 2.0},
      {"charlie", 800.0, 3.0},
      {"delta", 700.0, 4.0},
      {"echo", 600.0, 5.0},
      {"foxtrot", 100.0, 10.0}
    ]
    |> Enum.zip(people)
    |> Enum.each(&insert_llm_performance_rollups(&1, now))

    insert_e2e_rollup!(
      "qa.tokens.total",
      300.0,
      3,
      DateTime.add(now, -2 * 86_400, :second),
      %{"request_id" => "legacy-e2e"}
    )
  end

  defp insert_llm_performance_rollups({{model, tokens, calls}, person}, now) do
    agent_id = if model in ["alpha", "bravo", "charlie"], do: 101, else: 202
    agent_name = if agent_id == 101, do: "Support Agent", else: "Research Agent"

    dimensions = %{
      "configured_agent_id" => agent_id,
      "configured_agent_name" => agent_name,
      "llm_provider" => "openai",
      "llm_usage_attribution" => "v1",
      "model" => "e2e-#{model}",
      "person_id" => person.id
    }

    insert_e2e_rollup!("qa.llm.call.count", calls, 1, now, dimensions)
    insert_e2e_rollup!("qa.llm.tokens.prompt", tokens * 0.6, 1, now, dimensions)
    insert_e2e_rollup!("qa.llm.tokens.completion", tokens * 0.4, 1, now, dimensions)
    insert_e2e_rollup!("qa.llm.tokens.total", tokens, 1, now, dimensions)
  end

  defp insert_e2e_rollup!(metric_key, value_sum, value_count, bucket_start, dimensions) do
    Repo.insert!(%Rollup{
      metric_key: metric_key,
      bucket_start: bucket_start,
      bucket_size: "10m",
      source: "local",
      dimensions: dimensions,
      dimension_key: Telemetry.dimension_key(dimensions),
      value_sum: value_sum,
      value_count: value_count,
      value_min: value_sum,
      value_max: value_sum,
      last_value: value_sum,
      last_at: bucket_start
    })
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
