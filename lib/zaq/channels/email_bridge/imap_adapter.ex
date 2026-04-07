defmodule Zaq.Channels.EmailBridge.ImapAdapter do
  @moduledoc false

  alias Mailroom.IMAP
  alias Mailroom.IMAP.Envelope
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.EmailBridge.ImapAdapter.{Listener, Parser, RuntimeState}

  @fetch_items [:uid, :envelope, :rfc822_text, :header]
  @default_idle_timeout 1_500_000

  @spec to_internal(map(), map()) :: Zaq.Engine.Messages.Incoming.t() | {:error, term()}
  def to_internal(payload, connection_details)
      when is_map(payload) and is_map(connection_details) do
    mailbox = Map.get(connection_details, :mailbox) || Map.get(connection_details, "mailbox")
    Parser.to_incoming(payload, connection_details, mailbox: mailbox)
  end

  @spec connect(map(), String.t()) :: {:ok, pid()} | {:error, term()}
  def connect(config, mailbox) when is_binary(mailbox) do
    settings = ChannelConfig.imap_settings(config)
    server = Map.get(settings, "server") || config.url
    username = Map.get(settings, "username")
    password = config.token

    opts = [
      ssl: ssl?(settings),
      port: port(settings),
      timeout: timeout(settings)
    ]

    with {:ok, client} <- IMAP.connect(server, username, password, opts) do
      _ = IMAP.select(client, mailbox)
      {:ok, client}
    end
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

  @spec enter_idle(pid(), map()) :: :ok
  def enter_idle(client, config) when is_pid(client) do
    timeout = idle_timeout(ChannelConfig.imap_settings(config))
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

  @spec state_child_spec(map(), String.t()) :: map()
  def state_child_spec(config, bridge_id) when is_binary(bridge_id) do
    %{
      id: {RuntimeState, bridge_id},
      start: {RuntimeState, :start_link, [[bridge_id: bridge_id, config: config]]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec runtime_specs(map(), String.t(), keyword()) :: {:ok, {map(), [map()]}} | {:error, term()}
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
      {:ok, {state_child_spec(config, bridge_id), listeners}}
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
      |> ChannelConfig.imap_selected_mailboxes()
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
      "body_text" => Map.get(response, :rfc822_text),
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

  defp ssl?(settings), do: Map.get(settings, "ssl", true) != false

  defp port(settings) do
    fallback = default_port(settings)

    case Map.get(settings, "port") do
      port when is_integer(port) and port > 0 ->
        port

      port when is_binary(port) ->
        parse_positive_int(port, fallback)

      _ ->
        fallback
    end
  end

  defp default_port(settings), do: if(ssl?(settings), do: 993, else: 143)

  defp parse_positive_int(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp timeout(settings) do
    case Map.get(settings, "timeout") do
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

  defp idle_timeout(settings) do
    case Map.get(settings, "idle_timeout") do
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
end
