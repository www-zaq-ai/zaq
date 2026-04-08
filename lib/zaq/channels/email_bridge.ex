defmodule Zaq.Channels.EmailBridge do
  @moduledoc """
  Bridge for the email channel.

  Delivers `%Outgoing{}` via SMTP using the notification SMTP implementation.
  Connection details are not required — SMTP settings are read from
  `channel_configs.settings` under provider `email:smtp`.

  `to_internal/2` is a stub for future inbound email parsing.
  """

  require Logger

  alias Zaq.Channels.{Router, Supervisor}
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.NodeRouter

  @doc "Converts an email adapter payload to the internal `%Incoming{}` format."
  @spec to_internal(map(), map()) :: Incoming.t() | {:error, term()}
  def to_internal(params, connection_details)
      when is_map(params) and is_map(connection_details) do
    with {:ok, adapter} <- resolve_adapter(connection_details) do
      adapter.to_internal(params, connection_details)
    end
  end

  def to_internal(_params, _connection_details), do: {:error, :invalid_email_payload}

  @doc "Starts inbound email runtime processes for a channel config."
  def start_runtime(config) do
    bridge_id = default_bridge_id(config)
    provider = Map.get(config, :provider) || Map.get(config, "provider")

    with {:ok, adapter} <- adapter_for(provider),
         {:ok, prepared_config} <- normalize_imap_config(config),
         {:ok, {state_spec, listeners}} <-
           adapter.runtime_specs(
             prepared_config,
             bridge_id,
             sink_mfa: {__MODULE__, :from_listener, []},
             sink_opts: [bridge_id: bridge_id]
           ) do
      case Supervisor.start_runtime(bridge_id, state_spec, listeners) do
        {:ok, _runtime} ->
          :ok

        {:error, :already_running} ->
          restart_runtime(config, bridge_id, state_spec, listeners)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Stops IMAP runtime processes for an email:imap config."
  def stop_runtime(config) do
    case Supervisor.stop_bridge_runtime(config, default_bridge_id(config)) do
      :ok -> :ok
      {:error, :not_running} -> :ok
      other -> other
    end
  end

  @doc "Listener sink callback for incoming adapter payloads."
  def from_listener(config, payload, sink_opts)
      when is_map(payload) and is_list(sink_opts) do
    connection = sink_opts |> Enum.into(%{}) |> Map.put(:config, config)

    with %Incoming{} = incoming <- to_internal(payload, connection),
         outgoing <- run_pipeline(incoming),
         :ok <- deliver_outgoing(outgoing),
         :ok <- persist_from_incoming(incoming, outgoing.metadata) do
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
  def list_mailboxes(config, _connection_details \\ %{}) when is_map(config) do
    provider = Map.get(config, :provider) || Map.get(config, "provider")

    with {:ok, adapter} <- adapter_for(provider),
         {:ok, prepared_config} <- normalize_imap_config(config) do
      case adapter.list_mailboxes(prepared_config) do
        {:ok, mailboxes} when is_list(mailboxes) ->
          {:ok, normalize_mailboxes(mailboxes)}

        {:error, {:list_mailboxes_failed, {:ok, mailboxes}}} when is_list(mailboxes) ->
          {:ok, normalize_mailboxes(mailboxes)}

        other ->
          other
      end
    end
  end

  @doc """
  Delivers `%Outgoing{}` as an email to `outgoing.channel_id` (the recipient address).

  Reads subject and html_body from `outgoing.metadata` (keys `:subject` / `"subject"`
  and `:html_body` / `"html_body"`). Falls back to a default subject if missing.
  """
  @spec send_reply(Outgoing.t(), map()) :: :ok | {:error, term()}
  def send_reply(%Outgoing{} = outgoing, _connection_details) do
    alias Zaq.Engine.Notifications.EmailNotification

    reply? = email_reply?(outgoing)
    subject = resolve_subject(outgoing.metadata, reply?)
    from_email = resolve_from_email(outgoing.metadata, reply?)
    from_name = resolve_from_name(outgoing.metadata)

    html_body = get_meta(outgoing.metadata, "html_body", :html_body)
    headers = if reply?, do: reply_headers(outgoing), else: %{}

    payload =
      %{
        "subject" => subject,
        "body" => outgoing.body,
        "html_body" => html_body,
        "headers" => headers
      }
      |> maybe_put("from_email", from_email)
      |> maybe_put("from_name", from_name)

    EmailNotification.send_notification(outgoing.channel_id, payload, %{})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp default_bridge_id(config), do: "#{config.provider}_#{config.id}"

  defp restart_runtime(config, bridge_id, state_spec, listeners) do
    with :ok <- stop_runtime(config) do
      case Supervisor.start_runtime(bridge_id, state_spec, listeners) do
        {:ok, _runtime} -> :ok
        {:error, :already_running} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

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

  defp provider_key(provider) when is_atom(provider), do: provider

  defp provider_key(provider) when is_binary(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> :email
  end

  defp run_pipeline(%Incoming{} = msg) do
    module = pipeline_module()

    if module == Zaq.Agent.Pipeline do
      NodeRouter.call(:agent, module, :run, [msg, []])
    else
      module.run(msg, [])
    end
  end

  defp deliver_outgoing(%Outgoing{} = outgoing) do
    module = router_module()

    if module == Router do
      NodeRouter.call(:channels, module, :deliver, [outgoing])
    else
      module.deliver(outgoing)
    end
  end

  defp persist_from_incoming(%Incoming{} = incoming, metadata) when is_map(metadata) do
    module = conversations_module()

    if module == Zaq.Engine.Conversations do
      NodeRouter.call(:engine, module, :persist_from_incoming, [incoming, metadata])
    else
      module.persist_from_incoming(incoming, metadata)
    end
  end

  defp pipeline_module,
    do: Application.get_env(:zaq, :email_bridge_pipeline_module, Zaq.Agent.Pipeline)

  defp router_module,
    do: Application.get_env(:zaq, :email_bridge_router_module, Router)

  defp conversations_module,
    do: Application.get_env(:zaq, :email_bridge_conversations_module, Zaq.Engine.Conversations)

  # Handles both atom and string-keyed metadata (Oban args arrive as string keys).
  defp get_meta(metadata, string_key, atom_key) do
    Map.get(metadata, atom_key) || Map.get(metadata, string_key)
  end

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

  defp email_reply?(%Outgoing{} = outgoing) do
    provider = to_string(outgoing.provider)

    provider == "email:imap" and is_binary(outgoing.in_reply_to) and
      String.trim(outgoing.in_reply_to) != ""
  end

  defp reply_subject(nil), do: "Re: Notification from ZAQ"

  defp reply_subject(subject) when is_binary(subject) do
    trimmed = String.trim(subject)

    cond do
      trimmed == "" -> "Re: Notification from ZAQ"
      String.match?(trimmed, ~r/^re:\s*/i) -> trimmed
      true -> "Re: " <> trimmed
    end
  end

  defp reply_subject(_), do: "Re: Notification from ZAQ"

  defp reply_headers(%Outgoing{} = outgoing) do
    email_meta = get_meta(outgoing.metadata, "email", :email) || %{}
    threading = get_meta(email_meta, "threading", :threading) || %{}
    incoming_headers = get_meta(email_meta, "headers", :headers) || %{}
    in_reply_to = normalize_message_id(outgoing.in_reply_to)

    references =
      (get_meta(threading, "references", :references) ||
         get_meta(incoming_headers, "references", :references))
      |> references_list()
      |> append_once(in_reply_to)

    %{}
    |> maybe_put_header("In-Reply-To", format_message_id(in_reply_to))
    |> maybe_put_header("References", format_references(references))
  end

  defp references_list(nil), do: []

  defp references_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_message_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp references_list(value) when is_binary(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&normalize_message_id/1)
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

  defp normalize_message_id(nil), do: nil

  defp normalize_message_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_message_id(_), do: nil

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

  defp normalize_mailboxes(raw_mailboxes) when is_list(raw_mailboxes) do
    raw_mailboxes
    |> Enum.map(&mailbox_name/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp mailbox_name({mailbox, _delimiter, _flags}) when is_binary(mailbox), do: mailbox
  defp mailbox_name(%{mailbox: mailbox}) when is_binary(mailbox), do: mailbox
  defp mailbox_name(%{"mailbox" => mailbox}) when is_binary(mailbox), do: mailbox
  defp mailbox_name(mailbox) when is_binary(mailbox), do: mailbox
  defp mailbox_name(_), do: nil

  defp normalize_imap_config(config) when is_map(config) do
    imap_settings =
      config
      |> map_get(:settings)
      |> case do
        settings when is_map(settings) ->
          case Map.get(settings, "imap") || Map.get(settings, :imap) do
            map when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    selected_mailboxes =
      config
      |> map_get(:selected_mailboxes)
      |> case do
        nil -> map_get(imap_settings, :selected_mailboxes)
        list -> list
      end

    {:ok,
     %{
       provider: map_get(config, :provider) || "email:imap",
       url: map_get(config, :url),
       token: first_non_nil([map_get(config, :token), map_get(config, :password)]),
       username: first_non_nil([map_get(imap_settings, :username), map_get(config, :username)]),
       port: first_non_nil([map_get(imap_settings, :port), map_get(config, :port)]),
       ssl: first_non_nil([map_get(imap_settings, :ssl), map_get(config, :ssl)]),
       ssl_depth:
         first_non_nil([map_get(imap_settings, :ssl_depth), map_get(config, :ssl_depth)]),
       timeout: first_non_nil([map_get(imap_settings, :timeout), map_get(config, :timeout)]),
       idle_timeout:
         first_non_nil([map_get(imap_settings, :idle_timeout), map_get(config, :idle_timeout)]),
       poll_interval:
         first_non_nil([map_get(imap_settings, :poll_interval), map_get(config, :poll_interval)]),
       mark_as_read:
         first_non_nil([map_get(imap_settings, :mark_as_read), map_get(config, :mark_as_read)]),
       load_initial_unread:
         first_non_nil([
           map_get(imap_settings, :load_initial_unread),
           map_get(config, :load_initial_unread)
         ]),
       selected_mailboxes: normalize_mailboxes(List.wrap(selected_mailboxes))
     }}
  end

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_get(_map, _key), do: nil

  defp first_non_nil(values) when is_list(values) do
    Enum.find(values, fn value -> not is_nil(value) end)
  end
end
