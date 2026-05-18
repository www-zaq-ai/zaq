defmodule Zaq.Engine.Connect.GrantRefreshSchedulerWorker do
  @moduledoc "Schedules refresh jobs for OAuth grants nearing expiration."

  use Oban.Worker, queue: :channels, max_attempts: 1

  alias Zaq.Engine.Connect

  @window_seconds 600

  @impl Oban.Worker
  def perform(_job) do
    Connect.expiring_oauth_grants(DateTime.utc_now(), @window_seconds)
    |> Enum.each(fn grant ->
      _ = Connect.schedule_refresh(grant)
    end)

    :ok
  end
end
