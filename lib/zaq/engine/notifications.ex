defmodule Zaq.Engine.Notifications do
  @moduledoc """
  Notification center for ZAQ.

  The single exit point for all outbound communication from ZAQ to any user or
  person, across any channel. Other modules fire-and-forget. The notification
  center handles routing, filtering, retrying, and logging.

  ## Usage

      {:ok, notification} = Notification.build(%{
        recipient_channels: [%{platform: "email:smtp", identifier: "u@example.com"}],
        sender: "system",
        subject: "Hello",
        body: "World"
      })
      Notifications.notify(notification)
      # => {:ok, :dispatched} | {:ok, :skipped}

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

  alias Zaq.Accounts.People
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Engine.Notifications.DispatchWorker
  alias Zaq.Engine.Notifications.Notification
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Event
  alias Zaq.Repo

  @person_channel_platforms %{
    "email" => "email:smtp"
  }

  @doc """
  Returns true if a bridge is configured for the given platform string.
  """
  @spec bridge_available?(String.t(), keyword()) :: boolean()
  def bridge_available?(platform, opts \\ []) when is_binary(platform) do
    event =
      Event.new(%{platform: platform}, :channels,
        opts: [action: :bridge_available] |> maybe_put_config(opts)
      )

    node_router_module().dispatch(event)
    |> Map.get(:response, false)
    |> Kernel.==(true)
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Builds and dispatches a notification for a person.

  The person's configured channels define preferred/fallback delivery order via
  `PersonChannel.weight`; unavailable channels are filtered by `notify/1`.
  """
  @spec notify_person(term(), map(), keyword()) ::
          {:ok, :dispatched | :skipped} | {:error, term()}
  def notify_person(person_id, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, person} <- fetch_person(person_id, opts),
         {:ok, notification} <- build_person_notification(person, attrs) do
      notify(notification)
    end
  end

  @doc """
  Dispatches a validated `%Notification{}` struct.

  - Empty `recipient_channels` → logs `:skipped`, returns `{:ok, :skipped}`
  - Non-empty channels → enqueues an Oban `DispatchWorker` job, returns `{:ok, :dispatched}`

  Only accepts a `%Notification{}` struct — pass a plain map to
  `Notification.build/1` first.
  """
  @spec notify(Notification.t(), keyword()) :: {:ok, :dispatched} | {:ok, :skipped}
  def notify(notification, opts \\ [])

  def notify(%Notification{recipient_channels: []} = notification, _opts) do
    message =
      "[Notifications] skipped — no recipient_channels (sender=#{notification.sender}, recipient=#{notification.recipient_name})"

    Logger.info(message)

    {:ok, :skipped}
  end

  def notify(%Notification{} = notification, opts) do
    configured_platforms = configured_platforms()

    {channels, skipped_platforms} =
      Enum.reduce(notification.recipient_channels, {[], []}, fn ch, {configured, skipped} ->
        platform = Map.get(ch, :platform)
        identifier = Map.get(ch, :identifier)

        if platform in configured_platforms and bridge_available?(platform, opts) do
          entry = %{"platform" => platform, "identifier" => identifier}
          {configured ++ [entry], skipped}
        else
          {configured, skipped ++ [platform]}
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

    Enum.each(skipped_platforms, fn platform ->
      NotificationLog.append_attempt(log.id, platform, {:error, "not configured"})
    end)

    if channels == [] do
      NotificationLog.transition_status(log, "skipped")

      message =
        "[Notifications] skipped — no configured channels (sender=#{notification.sender}, log_id=#{log.id})"

      Logger.info(message)

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

  defp fetch_person(person_id, opts) do
    people_module = Keyword.get(opts, :people_module, People)

    case people_module.get_person_with_channels(person_id) do
      nil -> {:error, "person_not_found:#{person_id}"}
      person -> {:ok, person}
    end
  end

  defp build_person_notification(person, attrs) do
    Notification.build(%{
      recipient_name: person.full_name,
      recipient_ref: {:person, person.id},
      recipient_channels: person_channels(person),
      sender: get_attr(attrs, :sender, "system"),
      subject: get_attr(attrs, :subject),
      body: get_attr(attrs, :message) || get_attr(attrs, :body),
      html_body: get_attr(attrs, :html_body),
      metadata: get_attr(attrs, :metadata, %{})
    })
  end

  defp person_channels(person) do
    person.channels
    |> Enum.sort_by(& &1.weight)
    |> Enum.map(fn channel ->
      %{
        platform: Map.get(@person_channel_platforms, channel.platform, channel.platform),
        identifier: channel.channel_identifier
      }
    end)
  end

  defp get_attr(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, to_string(key), default))

  defp node_router_module,
    do: Application.get_env(:zaq, :notifications_node_router_module, Zaq.NodeRouter)

  defp maybe_put_config(event_opts, opts) do
    if Keyword.has_key?(opts, :config),
      do: Keyword.put(event_opts, :config, Keyword.fetch!(opts, :config)),
      else: event_opts
  end
end
