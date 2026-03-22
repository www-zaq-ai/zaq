defmodule Zaq.Engine.Notifications.DispatchWorker do
  @moduledoc """
  Oban worker that dispatches a notification through its resolved channels.

  Runs once (`max_attempts: 1`). Tries each channel sequentially and stops on
  the first success. All outcomes are recorded in `notification_logs`.

  Job args carry only `log_id`, `channels`, and `metadata` — the full payload
  (subject/body) is read from `notification_logs` at execution time.

  ## Channel format in args

      %{
        "platform"   => "email",
        "identifier" => "u@example.com",
        "adapter"    => "Elixir.Zaq.Engine.Notifications.Adapters.EmailAdapter"
      }
  """

  use Oban.Worker, queue: :notifications, max_attempts: 1

  require Logger

  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"log_id" => log_id, "channels" => channels} = args}) do
    log = Repo.get!(NotificationLog, log_id)
    metadata = Map.get(args, "metadata", %{})
    do_dispatch(log, channels, metadata)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_dispatch(log, [], _metadata) do
    NotificationLog.transition_status(log, "failed")

    Logger.warning("[DispatchWorker] log #{log.id} failed — all channels exhausted")

    :ok
  end

  defp do_dispatch(log, [ch | rest], metadata) do
    platform = ch["platform"]
    identifier = ch["identifier"]
    adapter = String.to_existing_atom(ch["adapter"])

    result = adapter.send(identifier, log.payload, metadata)
    NotificationLog.append_attempt(log.id, platform, result)

    case result do
      :ok ->
        {:ok, _} = NotificationLog.transition_status(log, "sent")
        :ok

      {:error, _reason} ->
        do_dispatch(log, rest, metadata)
    end
  end
end
