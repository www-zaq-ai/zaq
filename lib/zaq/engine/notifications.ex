defmodule Zaq.Engine.Notifications do
  @moduledoc """
  Notification center for ZAQ.

  The single exit point for all outbound communication from ZAQ to any user or
  person, across any channel. Other modules fire-and-forget. The notification
  center handles routing, filtering, fallback delivery, and logging.

  ## Usage

      {:ok, notification} = Notification.build(%{
        recipient_channels: [%{platform: "email:smtp", identifier: "u@example.com"}],
        sender: "system",
        subject: "Hello",
        body: "World"
      })
      Notifications.notify(notification)
      # => {:ok, %{status: :sent, channel: "email:smtp", channel_identifier: "u@example.com"}}

  ## Threading

  The notification center never interprets channel wire formats. Per attempt it
  resolves the prior-thread anchor (an opaque map) and passes it down on
  `Outgoing.thread_anchor`; the provider bridge interprets it, threads the send,
  and returns a delivery receipt whose `anchor` is persisted verbatim on the log.

  SMTP configuration and email threading mechanics live in
  `Zaq.Channels.EmailBridge` (see `docs/services/channels.md`).
  """

  require Logger

  import Ecto.Query

  alias Zaq.Accounts.People
  alias Zaq.Channels.Bridge
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.Events, as: ChannelEvents
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Engine.Notifications.Notification
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Event
  alias Zaq.Repo

  @person_channel_platforms %{
    "email" => "email:smtp"
  }

  @type notification_result :: %{
          required(:status) => :sent | :skipped | :failed,
          required(:notification_log_id) => integer() | nil,
          optional(:channel) => String.t() | nil,
          optional(:channel_identifier) => String.t() | nil,
          optional(:reason) => term(),
          # Threading pointers, surfaced on `:sent` only (never on skipped/failed,
          # so a message the recipient never received can't become a phantom parent).
          optional(:message_id) => String.t(),
          optional(:thread_id) => String.t(),
          optional(:thread_metadata) => map()
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
          {:ok, notification_result()} | {:error, term()}
  def notify_person(person_id, attrs, opts \\ []) when is_map(attrs) do
    with {:ok, person} <- fetch_person(person_id, opts),
         {:ok, notification} <- build_person_notification(person, attrs) do
      notify(notification, opts)
    end
  end

  @doc """
  Dispatches a validated `%Notification{}` struct.

  - Empty `recipient_channels` → returns a skipped result without creating a log
  - Non-empty channels → creates a log, tries each configured channel inline, and returns the final delivery result

  Only accepts a `%Notification{}` struct — pass a plain map to
  `Notification.build/1` first.
  """
  @spec notify(Notification.t(), keyword()) ::
          {:ok, notification_result()} | {:error, notification_result()}
  def notify(notification, opts \\ [])

  def notify(%Notification{recipient_channels: []} = notification, _opts) do
    message =
      "[Notifications] skipped — no recipient_channels (sender=#{notification.sender}, recipient=#{notification.recipient_name})"

    Logger.info(message)

    {:ok, %{status: :skipped, notification_log_id: nil, reason: :no_recipient_channels}}
  end

  def notify(%Notification{} = notification, opts) do
    configured_platforms = configured_platforms()

    {channels, skipped_channels} =
      Enum.reduce(notification.recipient_channels, {[], []}, fn ch, {configured, skipped} ->
        platform = Map.get(ch, :platform)
        identifier = Map.get(ch, :identifier)

        if platform in configured_platforms and bridge_available?(platform, opts) do
          entry = %{"platform" => platform, "identifier" => identifier}
          {configured ++ [entry], skipped}
        else
          {configured, skipped ++ [ch]}
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

    Enum.each(skipped_channels, fn channel ->
      NotificationLog.append_attempt(
        log.id,
        Map.get(channel, :platform),
        Map.get(channel, :identifier),
        {:error, "not configured"}
      )
    end)

    if channels == [] do
      NotificationLog.transition_status(log, "skipped")

      message =
        "[Notifications] skipped — no configured channels (sender=#{notification.sender}, log_id=#{log.id})"

      Logger.info(message)

      {:ok, %{status: :skipped, notification_log_id: log.id, reason: :no_configured_channels}}
    else
      dispatch_inline(log, channels, notification.metadata, opts, threading_ctx(notification))
    end
  end

  # Everything the email arm needs to resolve an anchor: who we are writing to and
  # the key their conversation is grouped under (`topic` first, then `subject` —
  # the same precedence persistence uses).
  defp threading_ctx(%Notification{} = notification) do
    person_id =
      case notification.recipient_ref do
        {:person, id} -> id
        _ -> nil
      end

    topic = metadata_value(notification.metadata, "topic")
    subject = notification.subject

    %{
      person_id: person_id,
      topic: topic,
      subject: subject,
      # The key the thread is chained under. `topic` first, then `subject` — the
      # same precedence conversation grouping uses. Blank → nil, which skips the
      # anchor entirely rather than risk chaining two unrelated leads together
      # under an empty key (Bug #8).
      thread_key: presence(topic) || presence(subject)
    }
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp metadata_value(_metadata, _key), do: nil

  defp dispatch_inline(log, [], _metadata, _opts, _ctx) do
    NotificationLog.transition_status(log, "failed")

    Logger.warning("[Notifications] log #{log.id} failed — all channels exhausted")

    {:error, %{status: :failed, notification_log_id: log.id, reason: :all_channels_failed}}
  end

  defp dispatch_inline(log, [channel | rest], metadata, opts, ctx) do
    platform = channel["platform"]
    identifier = channel["identifier"]

    case platform_to_atom(platform) do
      nil ->
        Logger.warning("[Notifications] unknown platform #{inspect(platform)}, skipping")
        dispatch_inline(log, rest, metadata, opts, ctx)

      provider ->
        # Resolved per attempt, not once per notification: on fallback the channel
        # that actually delivers must be the one whose anchor we store (Bug #12).
        anchor = resolve_anchor(platform, ctx)

        outgoing = %Outgoing{
          body: Map.get(log.payload, "body", ""),
          channel_id: identifier,
          provider: provider,
          thread_anchor: anchor,
          metadata:
            Map.merge(metadata, %{
              "subject" => Map.get(log.payload, "subject"),
              "html_body" => Map.get(log.payload, "html_body")
            })
        }

        result = deliver_via_channels(outgoing, opts)
        NotificationLog.append_attempt(log.id, platform, identifier, attempt_status(result))

        case result do
          {:ok, receipt} ->
            mark_sent(log, platform, identifier, receipt, ctx)

          {:error, _reason} ->
            # A failed attempt produces no receipt — nothing is surfaced or
            # persisted, so it can't become a phantom parent (Bug #3).
            dispatch_inline(log, rest, metadata, opts, ctx)
        end
    end
  end

  # The chain of messages we have actually sent this person under this key is the
  # source of truth, and it lives on the notification log — written on the sent
  # transition by the same code that saw delivery succeed. The conversation store
  # is consulted second: it carries the anchor for a thread ZAQ did not start (an
  # inbound message the person sent us) and for messages persisted by a workflow
  # before this path existed. The anchor is opaque here — only the provider bridge
  # interprets its contents.
  defp resolve_anchor(platform, %{person_id: person_id} = ctx) do
    NotificationLog.thread_anchor(person_id, ctx.thread_key) ||
      conversation_thread_anchor(person_id, platform, ctx)
  end

  # The grouping key and channel type come from the same Bridge dispatch that
  # persistence uses, so the anchor lookup and the message it anchors resolve
  # the same conversation. Platforms without conversation-inherited threading
  # resolve a nil key and skip the lookup entirely.
  defp conversation_thread_anchor(person_id, platform, ctx) do
    case Bridge.outbound_conversation_key(platform, ctx.topic, ctx.subject) do
      key when is_binary(key) ->
        Conversations.latest_thread_anchor(
          person_id,
          Bridge.conversation_channel_type(platform),
          key
        )

      _ ->
        nil
    end
  end

  defp attempt_status({:ok, _receipt}), do: :ok
  defp attempt_status({:error, _reason} = error), do: error

  defp mark_sent(log, platform, identifier, receipt, ctx) do
    base = %{
      status: :sent,
      notification_log_id: log.id,
      channel: platform,
      channel_identifier: identifier
    }

    result =
      case NotificationLog.transition_status(log, "sent") do
        {:ok, _} ->
          # Only now — the message is out. This is what the next send anchors onto,
          # with no downstream step required to carry it there.
          NotificationLog.record_threading(log, ctx.thread_key, receipt_anchor(receipt))

          base

        {:error, reason} ->
          Logger.warning(
            "[Notifications] log #{log.id} sent but status update failed: #{inspect(reason)}"
          )

          Map.put(base, :reason, reason)
      end

    {:ok, put_threading_result(result, receipt)}
  end

  defp receipt_anchor(receipt) do
    case Map.get(receipt, :anchor) || Map.get(receipt, "anchor") do
      anchor when is_map(anchor) -> anchor
      _ -> %{}
    end
  end

  # Threading pointers ride the receipt as the bridge returned them: generic
  # cross-channel pointers as named fields, channel-specific residue inside the
  # opaque `thread_metadata`.
  defp put_threading_result(result, receipt) when map_size(receipt) == 0, do: result

  defp put_threading_result(result, receipt) do
    [:message_id, :thread_id, :thread_metadata]
    |> Enum.reduce(result, fn key, acc ->
      case Map.get(receipt, key) || Map.get(receipt, Atom.to_string(key)) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp platform_to_atom(platform) when is_binary(platform) do
    Bridge.provider_to_bridge_key(platform)
  end

  defp platform_to_atom(_), do: nil

  defp deliver_via_channels(%Outgoing{} = outgoing, opts) do
    case ChannelEvents.build_and_dispatch_deliver_outgoing_event(outgoing,
           node_router: node_router_module(),
           event_opts: channels_event_opts(opts)
         ) do
      %{response: {:ok, receipt}} when is_map(receipt) -> {:ok, receipt}
      # A channels node still running the pre-receipt contract (rolling deploy).
      %{response: :ok} -> {:ok, %{}}
      %{response: {:error, _reason} = error} -> error
      _other -> {:error, :unexpected_response}
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
        identifier: delivery_identifier(channel)
      }
    end)
  end

  # `channel_identifier` identifies the person on the provider (for example a
  # Mattermost user id). `dm_channel_id`, when present, is the deliverable
  # direct-message channel id and must be preferred for outbound notifications.
  defp delivery_identifier(channel) do
    first_present([channel.dm_channel_id, channel.channel_identifier])
  end

  defp first_present(values) do
    Enum.find(values, fn
      value when is_binary(value) -> String.trim(value) != ""
      value -> not is_nil(value)
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

  defp channels_event_opts(opts), do: Keyword.get(opts, :channels_event_opts, [])
end
