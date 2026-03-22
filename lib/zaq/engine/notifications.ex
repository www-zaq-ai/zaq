defmodule Zaq.Engine.Notifications do
  @moduledoc """
  Notification center for ZAQ.

  The single exit point for all outbound communication from ZAQ to any user or
  person, across any channel. Other modules fire-and-forget. The notification
  center handles routing, filtering, retrying, and logging.

  ## Usage (new API — Phase 1+)

      {:ok, notification} = Notification.build(%{
        recipient_channels: [%{platform: "email", identifier: "u@example.com", preferred: true}],
        sender: "system",
        subject: "Hello",
        body: "World"
      })
      Notifications.notify(notification)
      # => {:ok, :dispatched} | {:ok, :skipped}

  ## Legacy API (deprecated — removed in Phase 0)

      Notifications.notify(user, %{subject: "...", body: "..."})

  ## SMTP Configuration (env vars)

  | Variable          | Default           | Description                  |
  |-------------------|-------------------|------------------------------|
  | SMTP_RELAY        | —                 | SMTP server hostname         |
  | SMTP_PORT         | 587               | SMTP port                    |
  | SMTP_USERNAME     | —                 | SMTP auth username           |
  | SMTP_PASSWORD     | —                 | SMTP auth password           |
  | SMTP_FROM_EMAIL   | noreply@zaq.local | Sender email address         |
  | SMTP_FROM_NAME    | ZAQ               | Sender display name          |
  | SMTP_TLS          | enabled           | TLS mode: enabled/always/never |
  """

  require Logger

  import Ecto.Query

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Notifications.DispatchWorker
  alias Zaq.Engine.Notifications.Notification
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Repo

  @adapter_registry %{
    "email" => Zaq.Engine.Notifications.Adapters.EmailAdapter,
    "mattermost" => Zaq.Engine.Notifications.Adapters.MattermostAdapter
  }

  @doc "Returns the adapter module for a given platform, or nil if not registered."
  @spec adapter_for(String.t()) :: module() | nil
  def adapter_for(platform), do: Map.get(@adapter_registry, platform)

  # ---------------------------------------------------------------------------
  # New API (Phase 1)
  # ---------------------------------------------------------------------------

  @doc """
  Dispatches a validated `%Notification{}` struct.

  - Empty `recipient_channels` → logs `:skipped`, returns `{:ok, :skipped}`
  - Non-empty channels → returns `{:ok, :dispatched}`
    (full channel resolution + Oban dispatch added in Phases 2–4)

  Only accepts a `%Notification{}` struct — pass a plain map to
  `Notification.build/1` first.
  """
  @spec notify(Notification.t()) :: {:ok, :dispatched} | {:ok, :skipped}
  def notify(%Notification{recipient_channels: []} = notification) do
    Logger.info(
      "[Notifications] skipped — no recipient_channels (sender=#{notification.sender}, recipient=#{notification.recipient_name})"
    )

    {:ok, :skipped}
  end

  def notify(%Notification{} = notification) do
    configured_platforms = configured_platforms()

    channels =
      notification.recipient_channels
      |> Enum.sort_by(fn ch -> if Map.get(ch, :preferred, false), do: 0, else: 1 end)
      |> Enum.flat_map(fn ch ->
        platform = Map.get(ch, :platform)
        identifier = Map.get(ch, :identifier)
        adapter = Map.get(@adapter_registry, platform)

        if platform in configured_platforms and adapter do
          [%{"platform" => platform, "identifier" => identifier, "adapter" => to_string(adapter)}]
        else
          []
        end
      end)

    {ref_type, ref_id} =
      case notification.recipient_ref do
        {type, id} -> {to_string(type), id}
        nil -> {nil, nil}
      end

    {:ok, log} =
      NotificationLog.create_log(%{
        sender: notification.sender,
        recipient_name: notification.recipient_name,
        recipient_ref_type: ref_type,
        recipient_ref_id: ref_id,
        payload: %{
          "subject" => notification.subject,
          "body" => notification.body,
          "html_body" => notification.html_body
        }
      })

    if channels == [] do
      NotificationLog.transition_status(log, "skipped")

      Logger.info(
        "[Notifications] skipped — no configured channels (sender=#{notification.sender}, log_id=#{log.id})"
      )

      {:ok, :skipped}
    else
      %{"log_id" => log.id, "channels" => channels, "metadata" => notification.metadata}
      |> DispatchWorker.new()
      |> Oban.insert!()

      {:ok, :dispatched}
    end
  end

  defp configured_platforms do
    from(c in ChannelConfig,
      where: c.kind == "retrieval" and c.enabled == true,
      select: c.provider
    )
    |> Repo.all()
    |> MapSet.new()
  end
end
