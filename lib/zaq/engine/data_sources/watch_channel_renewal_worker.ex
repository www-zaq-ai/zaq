defmodule Zaq.Engine.DataSources.WatchChannelRenewalWorker do
  @moduledoc """
  Renews expiring provider data-source watch channels.

  Jobs run on the `:channels` queue because renewal performs provider calls via
  the Channels boundary. Missing rows and already-stopped rows are no-ops; other
  provider or persistence failures are retried by Oban.
  """

  use Oban.Worker, queue: :channels, max_attempts: 3

  alias Zaq.Engine.DataSources

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"watch_channel_id" => id}}) do
    case DataSources.renew_watch_channel(id) do
      {:ok, _watch_channel} -> :ok
      :ok -> :ok
      {:error, :watch_channel_not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(_job), do: :ok
end
