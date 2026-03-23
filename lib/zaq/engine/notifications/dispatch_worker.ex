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
        "adapter"    => "Elixir.Zaq.Engine.Notifications.EmailNotification"
      }
  """

  use Oban.Worker, queue: :notifications, max_attempts: 1

  require Logger

  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"log_id" => log_id, "channels" => channels} = args}) do
    case Repo.get(NotificationLog, log_id) do
      nil ->
        Logger.warning("[DispatchWorker] log #{log_id} not found — cancelling job")
        {:cancel, :log_not_found}

      log ->
        metadata = Map.get(args, "metadata", %{})
        do_dispatch(log, channels, metadata)
    end
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
    adapter_str = ch["adapter"]

    case resolve_adapter(adapter_str) do
      nil ->
        Logger.warning(
          "[DispatchWorker] adapter #{inspect(adapter_str)} not available for platform #{inspect(platform)}, skipping"
        )

        do_dispatch(log, rest, metadata)

      adapter ->
        result = adapter.send_notification(identifier, log.payload, metadata)
        NotificationLog.append_attempt(log.id, platform, result)

        case result do
          :ok -> mark_sent(log)
          {:error, _reason} -> do_dispatch(log, rest, metadata)
        end
    end
  end

  defp mark_sent(log) do
    case NotificationLog.transition_status(log, "sent") do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[DispatchWorker] log #{log.id} sent but status update failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Safely resolves an adapter module string. Returns nil if the module is not
  # a known atom (String.to_existing_atom raises) or is not loaded.
  defp resolve_adapter(adapter_str) when is_binary(adapter_str) do
    module = String.to_existing_atom(adapter_str)
    if Code.ensure_loaded?(module), do: module, else: nil
  rescue
    ArgumentError -> nil
  end

  defp resolve_adapter(_), do: nil
end
