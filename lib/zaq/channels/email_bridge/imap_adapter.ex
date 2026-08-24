defmodule Zaq.Channels.EmailBridge.ImapAdapter do
  @moduledoc """
  IMAP adapter for the EmailBridge. Handles IMAP connections, IDLE listening,
  and email fetching for configured mailboxes.

  ## Responsibilities
  - Establishes IMAP connections with SSL/TLS support
  - Lists available mailboxes from the IMAP server
  - Manages IDLE connections for real-time email notifications
  - Fetches unseen emails and marks them as read
  - Converts raw IMAP responses to internal email payloads
  """

  require Logger

  alias Mailroom.IMAP.Envelope
  alias Zaq.Channels.EmailBridge.Attachment
  alias Zaq.Channels.EmailBridge.ImapAdapter.{Listener, MimeDecoder, MimeParts, Parser}
  alias Zaq.Channels.EmailBridge.ImapConfigHelpers
  alias Zaq.Channels.EmailBridge.TlsHelpers

  @fetch_items [:uid, :envelope, :body_structure, :header]
  @default_idle_timeout 1_500_000

  @spec to_internal(map(), map()) :: Zaq.Engine.Messages.Incoming.t() | {:error, term()}
  def to_internal(payload, connection_details)
      when is_map(payload) and is_map(connection_details) do
    mailbox = Map.get(connection_details, :mailbox) || Map.get(connection_details, "mailbox")
    Parser.to_incoming(payload, connection_details, mailbox: mailbox)
  end

  @spec connect(map(), String.t()) :: {:ok, pid()} | {:error, term()}
  def connect(config, mailbox) when is_binary(mailbox) do
    with {:ok, client} <- connect_client(config) do
      _ = imap_call(:select, [client, mailbox])
      {:ok, client}
    end
  end

  @spec list_mailboxes(map()) :: {:ok, [String.t()]} | {:error, term()}
  def list_mailboxes(config) do
    case connect_client(config) do
      {:ok, client} ->
        try do
          case imap_call(:list, [client]) do
            {:ok, list} when is_list(list) ->
              normalize_mailbox_names(list)

            list when is_list(list) ->
              normalize_mailbox_names(list)

            other ->
              {:error, {:list_mailboxes_failed, other}}
          end
        rescue
          error ->
            {:error, {:list_mailboxes_failed, Exception.format(:error, error, __STACKTRACE__)}}
        after
          _ = disconnect(client)
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:connect_failed, other}}
    end
  rescue
    error -> {:error, {:connect_failed, Exception.format(:error, error, __STACKTRACE__)}}
  end

  @spec fetch_unseen(pid(), String.t(), (map() -> any()), keyword()) :: :ok | {:error, term()}
  def fetch_unseen(client, mailbox, on_message, opts \\ [])

  def fetch_unseen(client, mailbox, on_message, opts)
      when is_pid(client) and is_binary(mailbox) do
    uid_validity = current_uid_validity(client, mailbox)
    config = Keyword.get(opts, :config, %{})

    imap_call(:search, [
      client,
      "UNSEEN",
      @fetch_items,
      fn {seq, response} ->
        response
        |> to_email_payload(seq, mailbox, uid_validity, client, config)
        |> on_message.()
      end
    ])

    :ok
  rescue
    error -> {:error, {:imap_fetch_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:imap_fetch_failed, reason}}
  end

  @spec fetch_body_section(pid(), pos_integer(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def fetch_body_section(client, sequence_or_uid, section, opts \\ [])
      when is_pid(client) and is_binary(section) do
    item = body_peek_item(section)

    {:ok, responses} = imap_call(:fetch, [client, sequence_or_uid, [item], nil, opts])

    with {:ok, response} <- first_fetch_response(responses) do
      fetch_response_body(response, section)
    end
  rescue
    error -> {:error, {:imap_fetch_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:imap_fetch_failed, reason}}
  end

  @spec enter_idle(pid(), map() | integer()) :: :ok
  def enter_idle(client, config_or_timeout) when is_pid(client) do
    timeout = idle_timeout(config_or_timeout)
    _ = imap_call(:idle, [client, self(), :idle_notify, [timeout: timeout]])
    :ok
  end

  @spec mark_as_read(pid(), integer()) :: :ok | {:error, term()}
  def mark_as_read(client, seq) when is_pid(client) and is_integer(seq) do
    _ = imap_call(:add_flags, [client, seq, [:seen]])
    :ok
  rescue
    error -> {:error, {:mark_as_read_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:mark_as_read_failed, reason}}
  end

  @spec download_attachment(map(), map()) :: {:ok, binary()} | {:error, term()}
  def download_attachment(config, locator) when is_map(config) and is_map(locator) do
    with {:ok, mailbox} <- fetch_locator_string(locator, :mailbox),
         {:ok, uid_validity} <- fetch_locator_positive_int(locator, :uid_validity),
         {:ok, uid} <- fetch_locator_positive_int(locator, :uid),
         {:ok, section} <- fetch_locator_string(locator, :section),
         true <- MimeParts.valid_section?(section) || {:error, :email_attachment_not_found},
         {:ok, client} <- connect(config, mailbox) do
      try do
        with current when current == uid_validity <- current_uid_validity(client, mailbox),
             _ <- imap_call(:mode, [client, :uid]),
             {:ok, encoded} <- fetch_body_section(client, uid, section),
             {:ok, decoded} <-
               MimeDecoder.decode_attachment(encoded, locator_value(locator, :encoding)) do
          {:ok, decoded}
        else
          current when is_integer(current) -> {:error, :stale_imap_uidvalidity}
          nil -> {:error, :stale_imap_uidvalidity}
          {:error, reason} -> {:error, reason}
        end
      after
        disconnect(client)
      end
    end
  end

  def download_attachment(_config, _locator), do: {:error, :invalid_media_request}

  @spec disconnect(pid()) :: :ok
  def disconnect(client) when is_pid(client) do
    _ = imap_call(:cancel_idle, [client])
    _ = imap_call(:logout, [client])
    :ok
  rescue
    _ -> :ok
  catch
    :exit, _reason -> :ok
  end

  @spec runtime_specs(map(), String.t(), keyword()) :: {:ok, {nil, [map()]}} | {:error, term()}
  def runtime_specs(config, bridge_id, opts \\ []) when is_binary(bridge_id) and is_list(opts) do
    sink_opts = Keyword.get(opts, :sink_opts, [])

    with {:ok, sink_mfa} <- fetch_sink_mfa(opts),
         {:ok, listeners} <-
           listener_child_specs(
             bridge_id,
             config: config,
             sink_mfa: sink_mfa,
             sink_opts: Keyword.put(sink_opts, :adapter, __MODULE__)
           ) do
      {:ok, {nil, listeners}}
    end
  end

  defp fetch_sink_mfa(opts) do
    case Keyword.get(opts, :sink_mfa) do
      {module, function, extra_args}
      when is_atom(module) and is_atom(function) and is_list(extra_args) ->
        {:ok, {module, function, extra_args}}

      _ ->
        {:error, :missing_sink_mfa}
    end
  end

  defp normalize_mailbox_names(list) do
    names = ImapConfigHelpers.normalize_mailbox_names(list)

    if Enum.all?(names, &String.valid?/1) do
      {:ok, names}
    else
      raise ArgumentError, "invalid UTF-8 mailbox name"
    end
  end

  @spec listener_child_specs(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def listener_child_specs(bridge_id, opts) when is_binary(bridge_id) and is_list(opts) do
    config = Keyword.fetch!(opts, :config)
    sink_mfa = Keyword.fetch!(opts, :sink_mfa)
    sink_opts = Keyword.get(opts, :sink_opts, [])

    specs =
      config
      |> selected_mailboxes()
      |> Enum.map(fn mailbox ->
        listener_child_spec(
          config,
          bridge_id,
          mailbox,
          sink_mfa,
          Keyword.put(sink_opts, :adapter, __MODULE__)
        )
      end)

    {:ok, specs}
  rescue
    KeyError -> {:error, :missing_listener_options}
  end

  defp listener_child_spec(config, bridge_id, mailbox, sink_mfa, sink_opts) do
    mailbox_id = String.downcase(mailbox)

    %{
      id: {Listener, "#{bridge_id}:#{mailbox_id}"},
      start:
        {Listener, :start_link,
         [
           [
             config: config,
             bridge_id: bridge_id,
             mailbox: mailbox,
             retry_interval: retry_interval(config),
             mark_as_read: mark_as_read?(config),
             load_initial_unread: load_initial_unread?(config),
             idle_timeout: idle_timeout(config),
             sink_mfa: sink_mfa,
             sink_opts: Keyword.put(sink_opts, :mailbox, mailbox)
           ]
         ]},
      restart: :permanent,
      type: :worker
    }
  end

  defp to_email_payload(response, seq, mailbox, uid_validity, client, config) do
    envelope = normalize_envelope(Map.get(response, :envelope))
    body_structure = Map.get(response, :body_structure)
    raw_header = fetch_response_header(response)
    bodies = fetch_message_bodies(client, seq, body_structure)
    uid = Map.get(response, :uid)
    from = first_sender(envelope.from)

    attachment_context = %{
      channel_config_id: config_get(config, :id),
      mailbox: mailbox,
      uid_validity: uid_validity,
      uid: uid,
      source_author_id: from.address
    }

    %{
      "mailbox" => mailbox,
      "seq" => seq,
      "uid" => uid,
      "uid_validity" => uid_validity,
      "channel_config_id" => config_get(config, :id),
      "subject" => envelope.subject,
      "from" => from,
      "message_id" => envelope.message_id,
      "in_reply_to" => envelope.in_reply_to,
      "references" => parse_references(raw_header),
      "raw_header" => raw_header,
      "body_text" => bodies.text,
      "body_html" => bodies.html,
      "attachments" =>
        body_structure
        |> MimeParts.attachment_parts()
        |> Attachment.to_records(attachment_context)
    }
  end

  defp fetch_message_bodies(client, seq, body_structure) do
    %{
      text: fetch_and_decode_body(client, seq, MimeParts.plain_text_part(body_structure)),
      html: fetch_and_decode_body(client, seq, MimeParts.html_part(body_structure))
    }
  end

  defp fetch_and_decode_body(_client, _seq, nil), do: nil

  defp fetch_and_decode_body(client, seq, %{section: section, encoding: encoding, params: params}) do
    with {:ok, body} <- fetch_body_section(client, seq, section),
         {:ok, decoded} <- MimeDecoder.decode_body(body, encoding, params) do
      decoded
    else
      _ -> nil
    end
  end

  defp current_uid_validity(client, mailbox) do
    case imap_call(:status, [client, mailbox, [:uid_validity]]) do
      {:ok, %{uid_validity: value}} when is_integer(value) -> value
      {:ok, %{"uid_validity" => value}} when is_integer(value) -> value
      %{uid_validity: value} when is_integer(value) -> value
      %{"uid_validity" => value} when is_integer(value) -> value
      value when is_integer(value) -> value
      _ -> state_uid_validity(client)
    end
  rescue
    _ -> state_uid_validity(client)
  catch
    :exit, _reason -> state_uid_validity(client)
  end

  defp state_uid_validity(client) do
    case imap_call(:state, [client]) do
      %{uid_validity: value} when is_integer(value) -> value
      %{"uid_validity" => value} when is_integer(value) -> value
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _reason -> nil
  end

  defp first_fetch_response([{_seq, response} | _]) when is_map(response), do: {:ok, response}
  defp first_fetch_response([response | _]) when is_map(response), do: {:ok, response}
  defp first_fetch_response(_), do: {:error, :email_body_section_not_found}

  defp fetch_response_body(response, section) when is_map(response) do
    expected_keys = body_response_keys(section)

    response
    |> Enum.find_value(fn
      {key, body} when is_binary(body) ->
        if normalized_fetch_body_key(key) in expected_keys, do: {:ok, body}

      _entry ->
        nil
    end)
    |> case do
      nil -> {:error, :email_body_section_not_found}
      result -> result
    end
  end

  defp fetch_response_header(response) when is_map(response) do
    case fetch_response_body(response, "HEADER") do
      {:ok, header} -> header
      {:error, _reason} -> nil
    end
  end

  defp body_response_keys(section) do
    section = String.upcase(section)

    keys = [body_peek_item(section), body_item(section)]

    if section == "HEADER", do: [:header | keys], else: keys
  end

  defp normalized_fetch_body_key(:header), do: :header
  defp normalized_fetch_body_key(key) when is_binary(key), do: String.upcase(key)

  defp normalized_fetch_body_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.upcase()

  defp normalized_fetch_body_key(_key), do: nil

  defp body_peek_item(section), do: "BODY.PEEK[#{section}]"
  defp body_item(section), do: "BODY[#{section}]"

  defp fetch_locator_string(locator, key) do
    case locator_value(locator, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_media_request}
    end
  end

  defp fetch_locator_positive_int(locator, key) do
    case locator_value(locator, key) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> {:ok, parsed}
          _ -> {:error, :invalid_media_request}
        end

      _ ->
        {:error, :invalid_media_request}
    end
  end

  defp locator_value(locator, key),
    do: Map.get(locator, key) || Map.get(locator, Atom.to_string(key))

  defp normalize_envelope(%Envelope{} = envelope), do: Envelope.normalize(envelope)
  defp normalize_envelope(_), do: %Envelope{}

  defp first_sender([address | _]) when is_map(address) do
    %{name: Map.get(address, :name), address: Map.get(address, :email)}
  end

  defp first_sender(_), do: %{name: nil, address: nil}

  defp parse_references(header) when is_binary(header) do
    case Regex.run(~r/^References:\s*(.+)$/im, header, capture: :all_but_first) do
      [refs] -> String.trim(refs)
      _ -> nil
    end
  end

  defp parse_references(_), do: nil

  defp connect_client(config) do
    {server, port_from_url} = endpoint_from_url(config_get(config, :url))

    if is_binary(server) and server != "" do
      username = config_get(config, :username)
      password = config_get(config, :token) || config_get(config, :password)
      ssl = ssl?(config)
      opts = connect_opts(config, ssl, port_from_url)

      try do
        imap_call(:connect, [server, username, password, opts])
      rescue
        error ->
          Logger.error(
            "[ImapAdapter] connect exception url=#{inspect(config_get(config, :url))} ssl=#{inspect(ssl)} port=#{inspect(opts[:port])} username=#{inspect(username)} reason=#{Exception.message(error)}"
          )

          reraise error, __STACKTRACE__
      catch
        :exit, reason ->
          normalized = normalize_connect_error(reason)

          Logger.error(
            "[ImapAdapter] connect exit url=#{inspect(config_get(config, :url))} ssl=#{inspect(ssl)} port=#{inspect(opts[:port])} username=#{inspect(username)} reason=#{inspect(normalized)} raw=#{inspect(reason)}"
          )

          {:error, {:connect_failed, normalized}}
      end
    else
      {:error, :invalid_imap_url}
    end
  end

  defp connect_opts(config, ssl, port_from_url) do
    opts = [
      ssl: ssl,
      port: port_from_url || port(config),
      timeout: timeout(config)
    ]

    if ssl do
      Keyword.put(opts, :ssl_opts,
        depth: ssl_depth(config),
        cacerts: TlsHelpers.default_cacerts()
      )
    else
      opts
    end
  end

  defp normalize_connect_error({:timeout, _}), do: :timeout
  defp normalize_connect_error({:noproc, _}), do: :noproc
  defp normalize_connect_error(reason), do: reason

  defp endpoint_from_url(nil), do: {nil, nil}

  defp endpoint_from_url(url) when is_binary(url) do
    normalized = String.trim(url)

    uri =
      if String.contains?(normalized, "://"),
        do: URI.parse(normalized),
        else: URI.parse("imap://#{normalized}")

    {uri.host, uri.port}
  end

  defp endpoint_from_url(_), do: {nil, nil}

  defp ssl?(config), do: config_get(config, :ssl, true) != false

  defp port(config) do
    fallback = default_port(config)

    case config_get(config, :port) do
      port when is_integer(port) and port > 0 ->
        port

      port when is_binary(port) ->
        parse_positive_int(port, fallback)

      _ ->
        fallback
    end
  end

  defp default_port(config), do: if(ssl?(config), do: 993, else: 143)

  defp parse_positive_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp timeout(config) do
    case config_get(config, :timeout) do
      v when is_integer(v) and v > 0 ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> 15_000
        end

      _ ->
        15_000
    end
  end

  defp ssl_depth(config) do
    case config_get(config, :ssl_depth, 3) do
      v when is_integer(v) and v >= 0 ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {parsed, ""} when parsed >= 0 -> parsed
          _ -> 3
        end

      _ ->
        3
    end
  end

  defp idle_timeout(config_or_timeout)
       when is_integer(config_or_timeout) and config_or_timeout > 0,
       do: config_or_timeout

  defp idle_timeout(config) do
    case config_get(config, :idle_timeout) do
      v when is_integer(v) and v > 0 ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> @default_idle_timeout
        end

      _ ->
        @default_idle_timeout
    end
  end

  defp retry_interval(config) do
    case config_get(config, :poll_interval) do
      v when is_integer(v) and v > 0 ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> 30_000
        end

      _ ->
        30_000
    end
  end

  defp mark_as_read?(config), do: config_get(config, :mark_as_read, true) != false

  defp load_initial_unread?(config), do: config_get(config, :load_initial_unread, false) == true

  defp selected_mailboxes(config) do
    ImapConfigHelpers.selected_mailboxes_for_listener(config)
  end

  defp config_get(config, key, default \\ nil)

  defp config_get(config, key, default) when is_map(config) and is_atom(key),
    do: ImapConfigHelpers.get(config, key, default)

  defp config_get(_config, _key, default), do: default

  defp imap_call(function, args),
    do:
      apply(
        Zaq.Config.get(:zaq, :imap_client, Zaq.Channels.EmailBridge.ImapClient),
        function,
        args
      )
end
