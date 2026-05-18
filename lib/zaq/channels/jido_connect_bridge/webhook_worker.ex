defmodule Zaq.Channels.JidoConnectBridge.WebhookWorker do
  @moduledoc """
  Processes verified datasource webhook deliveries asynchronously.
  """

  use Oban.Worker, queue: :channels, max_attempts: 3

  alias Zaq.Channels.JidoConnectBridge

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    case JidoConnectBridge.process_verified_webhook_job(args) do
      :ok ->
        :ok

      {:cancel, reason} ->
        {:cancel, reason}

      {:error, _reason} = error ->
        error
    end
  end
end
