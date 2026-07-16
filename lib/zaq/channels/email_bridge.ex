defmodule Zaq.Channels.EmailBridge do
  @moduledoc """
  Bridge for the email channel.

  Delivers `%Outgoing{}` via SMTP using the notification SMTP implementation.
  Connection details are not required — SMTP settings are read from
  `channel_configs.settings` under provider `email:smtp`.

  `to_internal/2` is a stub for future inbound email parsing.
  """

  @behaviour Zaq.Channels.Bridge
  @behaviour Zaq.Channels.CommunicationBridge
  use Zaq.Channels.Bridge
  use Zaq.Channels.CommunicationBridge

  require Logger

  alias Zaq.Channels.{AgentRouting, Bridge, ChannelConfig}
  alias Zaq.Channels.EmailBridge.ImapConfigHelpers
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.{NodeRouter, System}
  alias Zaq.Utils.EmailUtils

  @doc "Converts an email adapter payload to the internal `%Incoming{}` format."
  @spec to_internal(map(), map()) :: Incoming.t() | {:error, term()}
  @impl true
  def to_internal(params, connection_details)
      when is_map(params) and is_map(connection_details) do
    with {:ok, adapter} <- resolve_adapter(connection_details) do
      adapter.to_internal(params, connection_details)
    end
  end

  def to_internal(_params, _connection_details), do: {:error, :invalid_email_payload}

  @impl true
  def build_runtime_specs(config) do
    bridge_id = runtime_bridge_id(config)
    provider = Map.get(config, :provider) || Map.get(config, "provider")

    with {:ok, adapter} <- adapter_for(provider),
         {:ok, prepared_config} <- normalize_imap_config(config) do
      adapter.runtime_specs(
        prepared_config,
        bridge_id,
        sink_mfa: {__MODULE__, :from_listener, []},
        sink_opts: [bridge_id: bridge_id]
      )
    end
  end

  @impl true
  def sync_provider_runtime(%{enabled: false} = config), do: stop_runtime(config)

  def sync_provider_runtime(%{enabled: true} = config),
    do: Bridge.restart_runtime(__MODULE__, config)

  @doc "Listener sink callback for incoming adapter payloads."
  def from_listener(config, payload, sink_opts)
      when is_map(payload) and is_list(sink_opts) do
    route_incoming(__MODULE__, config, payload, sink_opts)
  end

  @doc "Processes a normalized inbound payload from listener sink."
  def handle_from_listener(config, payload, sink_opts)
      when is_map(payload) and is_list(sink_opts) do
    connection = sink_opts |> Enum.into(%{}) |> Map.put(:config, config)

    with %Incoming{} = incoming <- to_internal(payload, connection),
         :ok <- route_and_maybe_deliver_incoming(incoming, config, connection) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "[EmailBridge] Failed to process inbound message provider=#{config.provider} reason=#{inspect(reason)}"
        )

        {:error, reason}

      other ->
        Logger.warning(
          "[EmailBridge] Failed to process inbound message provider=#{config.provider} reason=#{inspect(other)}"
        )

        {:error, other}
    end
  end

  @doc "Lists available IMAP mailboxes through the configured email adapter."
  @spec list_mailboxes(map(), map()) :: {:ok, [String.t()]} | {:error, term()}
  @impl true
  def list_mailboxes(config, _connection_details \\ %{}) when is_map(config) do
    provider = Map.get(config, :provider) || Map.get(config, "provider")

    with {:ok, adapter} <- adapter_for(provider),
         {:ok, prepared_config} <- normalize_imap_config(config) do
      case adapter.list_mailboxes(prepared_config) do
        {:ok, mailboxes} when is_list(mailboxes) ->
          {:ok, ImapConfigHelpers.normalize_mailbox_names(mailboxes)}

        {:error, {:list_mailboxes_failed, {:ok, mailboxes}}} when is_list(mailboxes) ->
          {:ok, ImapConfigHelpers.normalize_mailbox_names(mailboxes)}

        other ->
          other
      end
    end
  end

  @doc """
  Conversation grouping key for an inbound or persisted email message.

  Precedence: the parser's `email.thread_key` (root-reference grouping), a
  top-level `thread_key`, the outbound `topic`/`subject` key, then normalized
  RFC message ids. Returns `nil` when nothing resolves — the caller owns any
  generic fallback (author id).
  """
  @impl true
  @spec conversation_key(Incoming.t()) :: String.t() | nil
  def conversation_key(%Incoming{} = incoming) do
    email_meta =
      case get_meta(incoming.metadata, "email", :email) do
        meta when is_map(meta) -> meta
        _ -> %{}
      end

    first_present([
      get_meta(email_meta, "thread_key", :thread_key),
      get_meta(incoming.metadata, "thread_key", :thread_key),
      outbound_conversation_key(
        get_meta(incoming.metadata, "topic", :topic),
        get_meta(incoming.metadata, "subject", :subject)
      )
    ]) ||
      EmailUtils.normalize_message_id(incoming.thread_id) ||
      EmailUtils.normalize_message_id(incoming.message_id)
  end

  @doc """
  Conversation grouping key for an outbound-first email send: `topic`, falling
  back to `subject`. Blank strings are skipped; `nil` when both are blank.

  Outbound sends carry no inbound headers, so grouping collapses to this key —
  persistence and anchor lookup both route through it so the anchor and the
  message it anchors resolve the same conversation.
  """
  @impl true
  @spec outbound_conversation_key(String.t() | nil, String.t() | nil) :: String.t() | nil
  def outbound_conversation_key(topic, subject), do: first_present([topic, subject])

  defp first_present(values) do
    Enum.find(values, fn
      value when is_binary(value) -> String.trim(value) != ""
      value -> not is_nil(value)
    end)
  end

  @doc """
  Delivers `%Outgoing{}` as an email to `outgoing.channel_id` (the recipient address).

  Reads subject and html_body from `outgoing.metadata` (keys `:subject` / `"subject"`
  and `:html_body` / `"html_body"`). Falls back to a default subject if missing.
  """
  @spec send_reply(Outgoing.t(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def send_reply(%Outgoing{} = outgoing, _connection_details) do
    # Two independent predicates. `inbound_reply?` is about *provenance* (are we
    # answering an email someone sent us) and drives the `Re:` prefix. Continuity
    # (do we have a parent to point at) comes from `thread_anchor`/`in_reply_to`
    # and drives the RFC headers. A proactive sequence is the second without the
    # first: it threads via headers while keeping the clean subject its campaign
    # topic defines.
    inbound_reply? = inbound_reply?(outgoing)

    subject = resolve_subject(outgoing.metadata, inbound_reply?)
    from_email = resolve_from_email(outgoing.metadata, inbound_reply?)
    from_name = resolve_from_name(outgoing.metadata)

    html_body = get_meta(outgoing.metadata, "html_body", :html_body)
    format = get_meta(outgoing.metadata, "format", :format)

    threading = resolve_threading(outgoing)
    headers = threading_headers(threading)

    payload =
      %{
        "subject" => subject,
        "body" => outgoing.body,
        "html_body" => html_body,
        "format" => format,
        "headers" => headers
      }
      |> maybe_put("from_email", from_email)
      |> maybe_put("from_name", from_name)

    case notification_module().send_notification(outgoing.channel_id, payload, %{}) do
      :ok -> {:ok, delivery_receipt(threading)}
      error -> error
    end
  end

  defp notification_module do
    Zaq.Config.get(
      :zaq,
      :email_bridge_notification_module,
      Zaq.Engine.Notifications.EmailNotification
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp route_and_maybe_deliver_incoming(%Incoming{} = incoming, config, connection) do
    case route_incoming_message(
           incoming,
           [],
           agent_candidates(config, connection[:mailbox]),
           actor_from_incoming(incoming),
           channel_config_id: Map.get(config, :id) || Map.get(config, "id"),
           pipeline_module: pipeline_module(),
           node_router: node_router_module()
         ) do
      %Outgoing{} = outgoing -> normalize_runtime_delivery(deliver_outgoing_runtime(outgoing))
      :ok -> :ok
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  # The inbound-reply runtime path has no use for the delivery receipt — collapse
  # it so `handle_from_listener` keeps matching on `:ok`.
  defp normalize_runtime_delivery({:ok, receipt}) when is_map(receipt), do: :ok
  defp normalize_runtime_delivery(other), do: other

  defp resolve_adapter(connection_details) do
    case Map.get(connection_details, :adapter) || Map.get(connection_details, "adapter") do
      module when is_atom(module) and not is_nil(module) -> {:ok, module}
      _ -> adapter_from_provider(connection_details)
    end
  end

  defp adapter_from_provider(connection_details) do
    provider =
      connection_details
      |> Map.get(:config)
      |> case do
        %{provider: provider} -> provider
        _ -> "email:imap"
      end

    adapter_for(provider)
  end

  defp adapter_for(provider) do
    with key when not is_nil(key) <- provider_key(provider),
         adapter when is_atom(adapter) <-
           Application.get_env(:zaq, :channels, %{}) |> get_in([key, :adapter]) do
      {:ok, adapter}
    else
      _ -> {:error, {:unsupported_provider, provider}}
    end
  end

  defp provider_key(provider) when is_binary(provider) do
    Bridge.provider_to_bridge_key(provider) || :email
  end

  defp provider_key(provider), do: Bridge.provider_to_bridge_key(provider)

  @impl true
  def resolve_agent_selection(config, %Incoming{} = _incoming, opts) do
    mailbox = Keyword.get(opts, :mailbox)

    config
    |> agent_candidates(mailbox)
    |> AgentRouting.first_active_selection()
  end

  defp agent_candidates(config, mailbox) do
    [
      {:mailbox_assignment, mailbox_assignment_agent_choice(config, mailbox)},
      {:provider_default, ChannelConfig.get_provider_agent_choice(config)},
      {:global_default, System.get_global_default_agent_id()}
    ]
  end

  defp mailbox_assignment_agent_choice(config, mailbox) do
    mailbox = normalize_mailbox(mailbox)

    with mailbox when is_binary(mailbox) <- mailbox,
         settings when is_map(settings) <-
           Map.get(config, :settings) || Map.get(config, "settings"),
         imap when is_map(imap) <- Map.get(settings, "imap"),
         routing when is_map(routing) <- Map.get(imap, "agent_routing"),
         mailboxes when is_map(mailboxes) <- Map.get(routing, "mailboxes") do
      Map.get(mailboxes, mailbox)
    else
      _ -> nil
    end
  end

  defp normalize_mailbox(mailbox) when is_binary(mailbox) do
    case String.trim(mailbox) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_mailbox(_), do: nil

  # person is resolved by CommunicationBridge before dispatching to the agent node.
  defp actor_from_incoming(%Incoming{} = incoming) do
    %{
      id: incoming.author_id,
      name: incoming.author_name,
      provider: incoming.provider
    }
  end

  defp pipeline_module,
    do: Application.get_env(:zaq, :email_bridge_pipeline_module, Zaq.Agent.Pipeline)

  defp node_router_module,
    do: Application.get_env(:zaq, :email_bridge_node_router_module, NodeRouter)

  defp deliver_outgoing_runtime(%Outgoing{} = outgoing) do
    case Application.get_env(:zaq, :email_bridge_router_module, Zaq.Channels.Api) do
      Zaq.Channels.Api ->
        Zaq.Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])
        |> node_router_module().dispatch()
        |> then(& &1.response)

      module when is_atom(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :deliver, 1) do
          module.deliver(outgoing)
        else
          Zaq.Event.new(outgoing, :channels, opts: [action: :deliver_outgoing])
          |> node_router_module().dispatch()
          |> then(& &1.response)
        end
    end
  end

  # Handles both atom and string-keyed metadata (Oban args arrive as string keys).
  defp get_meta(metadata, string_key, atom_key) when is_map(metadata) do
    Map.get(metadata, atom_key) || Map.get(metadata, string_key)
  end

  defp get_meta(_metadata, _string_key, _atom_key), do: nil

  defp resolve_subject(metadata, reply?) when is_map(metadata) do
    subject =
      get_meta(metadata, "subject", :subject) ||
        metadata
        |> get_meta("email", :email)
        |> case do
          email_meta when is_map(email_meta) -> get_meta(email_meta, "subject", :subject)
          _ -> nil
        end || "Notification from ZAQ"

    if reply?, do: reply_subject(subject), else: subject
  end

  defp resolve_subject(_metadata, reply?) do
    if reply?, do: "Re: Notification from ZAQ", else: "Notification from ZAQ"
  end

  # Provenance: we are answering an email that was sent *to* us. Drives `Re:`.
  defp inbound_reply?(%Outgoing{} = outgoing) do
    to_string(outgoing.provider) == "email:imap" and has_parent?(outgoing)
  end

  defp has_parent?(%Outgoing{in_reply_to: in_reply_to}) do
    is_binary(in_reply_to) and String.trim(in_reply_to) != ""
  end

  # Resolves the full set of RFC 5322 threading pointers for this send.
  #
  # The message's own id is pre-minted metadata when a caller supplied one,
  # otherwise minted here — gen_smtp would let the relay assign one ZAQ never
  # learns, so ours must be the id that is delivered. The parent comes from the
  # opaque `thread_anchor` (the last message ZAQ delivered in this thread) when
  # the notification center resolved one, else from `in_reply_to` (an inbound
  # email being answered).
  defp resolve_threading(%Outgoing{} = outgoing) do
    email_meta = get_meta(outgoing.metadata, "email", :email) || %{}
    preminted = get_meta(email_meta, "threading", :threading) || %{}
    incoming_headers = get_meta(email_meta, "headers", :headers) || %{}
    anchor = outgoing.thread_anchor || %{}

    anchor_parent = EmailUtils.normalize_message_id(get_meta(anchor, "message_id", :message_id))
    in_reply_to = anchor_parent || EmailUtils.normalize_message_id(outgoing.in_reply_to)

    message_id =
      EmailUtils.normalize_message_id(get_meta(preminted, "message_id", :message_id)) ||
        EmailUtils.new_message_id(sending_domain())

    references = chain_references(in_reply_to, anchor_parent, anchor, preminted, incoming_headers)

    %{
      message_id: message_id,
      in_reply_to: in_reply_to,
      references: references,
      # The root of the thread — or, on a first send, the message itself.
      thread_id: get_meta(anchor, "thread_id", :thread_id) || List.first(references) || message_id
    }
  end

  # No parent → fresh thread, no ancestor chain (References without a parent
  # would claim a continuity that does not exist).
  defp chain_references(nil, _anchor_parent, _anchor, _preminted, _incoming_headers), do: []

  defp chain_references(in_reply_to, anchor_parent, anchor, preminted, incoming_headers) do
    anchor_parent
    |> ancestor_references(anchor, preminted, incoming_headers)
    |> append_once(in_reply_to)
    |> EmailUtils.cap_references()
  end

  defp ancestor_references(anchor_parent, anchor, preminted, incoming_headers) do
    if anchor_parent do
      references_list(get_meta(anchor, "references", :references))
    else
      references_list(
        get_meta(preminted, "references", :references) ||
          get_meta(incoming_headers, "references", :references)
      )
    end
  end

  defp threading_headers(threading) do
    %{"Message-ID" => format_message_id(threading.message_id)}
    |> maybe_put_header("In-Reply-To", format_message_id(threading.in_reply_to))
    |> maybe_put_header("References", format_references(threading.references))
  end

  # The delivery receipt returned to the caller: generic pointers as named fields,
  # the email-only chain inside the opaque residue, and the `anchor` map the
  # notification center persists verbatim for the next send to chain onto.
  defp delivery_receipt(threading) do
    anchor = %{
      "message_id" => threading.message_id,
      "in_reply_to" => threading.in_reply_to,
      "references" => threading.references,
      "thread_id" => threading.thread_id
    }

    %{
      message_id: threading.message_id,
      thread_id: threading.thread_id,
      anchor: anchor,
      thread_metadata: %{
        # Channel-agnostic anchor the engine stores and reads back opaquely.
        "threading" => %{"anchor" => anchor},
        "email" => %{
          "threading" => %{
            "message_id" => threading.message_id,
            "in_reply_to" => threading.in_reply_to,
            "references" => threading.references
          }
        }
      }
    }
  end

  defp sending_domain do
    case ChannelConfig.get_by_provider("email:smtp") do
      %ChannelConfig{settings: settings} when is_map(settings) ->
        EmailUtils.sending_domain(Map.get(settings, "from_email"))

      _ ->
        EmailUtils.sending_domain(nil)
    end
  end

  defp reply_subject(subject) when is_binary(subject) do
    trimmed = String.trim(subject)

    cond do
      trimmed == "" -> "Re: Notification from ZAQ"
      String.match?(trimmed, ~r/^re:\s*/i) -> trimmed
      true -> "Re: " <> trimmed
    end
  end

  defp references_list(nil), do: []

  defp references_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&EmailUtils.normalize_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp references_list(value) when is_binary(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&EmailUtils.normalize_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp references_list(_), do: []

  defp append_once(values, nil), do: values

  defp append_once(values, value) when is_list(values) do
    if value in values, do: values, else: values ++ [value]
  end

  defp maybe_put_header(headers, _key, nil), do: headers
  defp maybe_put_header(headers, _key, ""), do: headers
  defp maybe_put_header(headers, key, value), do: Map.put(headers, key, value)

  defp format_references([]), do: nil

  defp format_references(references) do
    references
    |> Enum.map(&format_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp format_message_id(nil), do: nil
  defp format_message_id(value), do: "<" <> value <> ">"

  defp resolve_from_email(metadata, reply?) when is_map(metadata) do
    explicit =
      get_meta(metadata, "from_email", :from_email) ||
        sender_email(get_meta(metadata, "from", :from))

    normalize_non_blank(explicit) || reply_from_email(metadata, reply?)
  end

  defp resolve_from_email(_metadata, _reply?), do: nil

  defp reply_from_email(_metadata, false), do: nil

  defp reply_from_email(metadata, true) do
    metadata
    |> get_meta("email", :email)
    |> case do
      email_meta when is_map(email_meta) -> get_meta(email_meta, "reply_from", :reply_from)
      _ -> nil
    end
    |> normalize_non_blank()
  end

  defp normalize_non_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_non_blank(_), do: nil

  defp resolve_from_name(metadata) when is_map(metadata) do
    get_meta(metadata, "from_name", :from_name) || sender_name(get_meta(metadata, "from", :from))
  end

  defp resolve_from_name(_metadata), do: nil

  defp sender_email({_, email}) when is_binary(email), do: String.trim(email)
  defp sender_email(%{email: email}) when is_binary(email), do: String.trim(email)
  defp sender_email(%{"email" => email}) when is_binary(email), do: String.trim(email)
  defp sender_email(%{address: email}) when is_binary(email), do: String.trim(email)
  defp sender_email(%{"address" => email}) when is_binary(email), do: String.trim(email)
  defp sender_email(email) when is_binary(email), do: String.trim(email)
  defp sender_email(_), do: nil

  defp sender_name({name, _email}) when is_binary(name), do: String.trim(name)
  defp sender_name(%{name: name}) when is_binary(name), do: String.trim(name)
  defp sender_name(%{"name" => name}) when is_binary(name), do: String.trim(name)
  defp sender_name(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_imap_config(config) when is_map(config) do
    {:ok, ImapConfigHelpers.normalize_bridge_config(config)}
  end
end
