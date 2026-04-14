defmodule Zaq.Engine.Telemetry.Workers.PrunePointsWorker do
  @moduledoc """
  Deletes old raw telemetry points to keep storage bounded.
  """

  use Oban.Worker, queue: :telemetry, max_attempts: 3

  import Ecto.Query

  alias Zaq.Engine.Telemetry.Point
  alias Zaq.Repo
  alias Zaq.System

  @impl Oban.Worker
  def perform(_job) do
    retention_days =
      "telemetry.raw_retention_days"
      |> System.get_config()
      |> parse_int(60)

    cutoff = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    from(p in Point, where: p.occurred_at < ^cutoff)
    |> Repo.delete_all()

    :ok
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> default
    end
  end
end
