defmodule Zaq.Channels.EmailBridge.ImapAdapter do
  @moduledoc false

  require Logger

  alias Mailroom.IMAP
  alias Mailroom.IMAP.Envelope
  alias Zaq.Channels.EmailBridge.ImapAdapter.{Listener, Parser}
  alias Zaq.Channels.EmailBridge.ImapConfigHelpers

  @fetch_items [:uid, :envelope, :rfc822, :header]
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
      _ = IMAP.select(client, mailbox)
      {:ok, client}
    end
  end

  @spec list_mailboxes(map()) :: {:ok, [String.t()]} | {:error, term()}
  def list_mailboxes(config) do
    case connect_client(config) do
      {:ok, client} ->
        try do
          case IMAP.list(client) do
            {:ok, list} when is_list(list) ->
              {:ok, ImapConfigHelpers.normalize_mailbox_names(list)}

            list when is_list(list) ->
              {:ok, ImapConfigHelpers.normalize_mailbox_names(list)}

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

  @spec fetch_unseen(pid(), String.t(), (map() -> any())) :: :ok | {:error, term()}
  def fetch_unseen(client, mailbox, on_message) when is_pid(client) and is_binary(mailbox) do
    IMAP.search(client, "UNSEEN", @fetch_items, fn {seq, response} ->
      response
      |> to_email_payload(seq, mailbox)
      |> on_message.()
    end)

    :ok
  rescue
    error -> {:error, {:imap_fetch_failed, Exception.message(error)}}
  end

  @spec enter_idle(pid(), map() | integer()) :: :ok
  def enter_idle(client, config_or_timeout) when is_pid(client) do
    timeout = idle_timeout(config_or_timeout)
    _ = IMAP.idle(client, self(), :idle_notify, timeout: timeout)
    :ok
  end

  @spec mark_as_read(pid(), integer()) :: :ok | {:error, term()}
  def mark_as_read(client, seq) when is_pid(client) and is_integer(seq) do
    _ = IMAP.add_flags(client, seq, [:seen])
    :ok
  rescue
    error -> {:error, {:mark_as_read_failed, Exception.message(error)}}
  end

  @spec disconnect(pid()) :: :ok
  def disconnect(client) when is_pid(client) do
    _ = IMAP.cancel_idle(client)
    _ = IMAP.logout(client)
    :ok
  rescue
    _ -> :ok
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

  defp to_email_payload(response, seq, mailbox) do
    envelope = normalize_envelope(Map.get(response, :envelope))

    %{
      "mailbox" => mailbox,
      "seq" => seq,
      "uid" => Map.get(response, :uid),
      "subject" => envelope.subject,
      "from" => first_sender(envelope.from),
      "message_id" => envelope.message_id,
      "in_reply_to" => envelope.in_reply_to,
      "references" => parse_references(Map.get(response, :header)),
      "raw_rfc822" => Map.get(response, :rfc822),
      "body_html" => nil,
      "attachments" => []
    }
  end

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

    username = config_get(config, :username)
    password = config_get(config, :token) || config_get(config, :password)
    ssl = ssl?(config)

    opts = [
      ssl: ssl,
      ssl_opts: [depth: ssl_depth(config), cacerts: :public_key.cacerts_get()],
      port: port_from_url || port(config),
      timeout: timeout(config)
    ]

    if is_binary(server) and server != "" do
      try do
        IMAP.connect(server, username, password, opts)
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
end
