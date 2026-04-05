defmodule Zaq.Engine.Notifications.DispatchWorker do
  @moduledoc """
  Oban worker that dispatches a notification through its resolved channels.

  Runs once (`max_attempts: 1`). Tries each channel sequentially and stops on
  the first success. All outcomes are recorded in `notification_logs`.

  Delivery is performed by `Zaq.Channels.Router.deliver/1`, which resolves the
  correct bridge from app config and calls `bridge.send_reply/2`.

  Job args carry only `log_id`, `channels`, and `metadata` — the full payload
  (subject/body) is read from `notification_logs` at execution time.

  ## Channel format in args

      %{
        "platform"   => "email:smtp",
        "identifier" => "u@example.com"
      }
  """

  use Oban.Worker, queue: :notifications, max_attempts: 1

  require Logger

  alias Zaq.Channels.Router
  alias Zaq.Engine.Messages.Outgoing
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

    case platform_to_atom(platform) do
      nil ->
        Logger.warning("[DispatchWorker] unknown platform #{inspect(platform)}, skipping")

        do_dispatch(log, rest, metadata)

      provider ->
        outgoing = %Outgoing{
          body: Map.get(log.payload, "body", ""),
          channel_id: identifier,
          provider: provider,
          metadata:
            Map.merge(metadata, %{
              "subject" => Map.get(log.payload, "subject"),
              "html_body" => Map.get(log.payload, "html_body")
            })
        }

        result = router_mod().deliver(outgoing)
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

  defp platform_to_atom(platform) when is_binary(platform) do
    case platform do
      "email:smtp" -> :email
      _other -> String.to_existing_atom(platform)
    end
  rescue
    ArgumentError -> nil
  end

  defp platform_to_atom(_), do: nil

  defp router_mod,
    do: Application.get_env(:zaq, :dispatch_worker_router_module, Router)
end
