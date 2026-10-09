defmodule Zaq.Channels.EmailBridge.ImapAdapter.Parser do
  @moduledoc false

  alias Mail
  alias Mail.Parsers.RFC2822
  alias Zaq.Channels.EmailBridge.ImapAdapter.Threading
  alias Zaq.Channels.EmailBridge.SelfAddresses
  alias Zaq.Channels.MessageTimestamp
  alias Zaq.Contracts.Record
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Utils.EmailUtils

  @spec to_incoming(map(), map(), keyword()) :: Incoming.t() | {:error, term()}
  def to_incoming(raw_email, config, opts \\ [])

  def to_incoming(raw_email, config, opts) when is_map(raw_email) and is_list(opts) do
    mailbox = Keyword.get(opts, :mailbox)
    parsed_email = parse_email(parsed_email_source(raw_email))
    bodies = extract_bodies(raw_email, parsed_email)
    headers = extract_headers(raw_email, parsed_email)
    subject = extract_subject(raw_email, parsed_email)
    configured_address = configured_address(config)
    receiving_address = receiving_address(raw_email)
    reply_from = receiving_address || configured_address
    own_addresses = Enum.reject([configured_address, receiving_address], &is_nil/1)

    message_id = headers["message_id"]
    thread_id = Threading.resolve_thread_id(headers)
    thread_key = Threading.resolve_thread_key(headers) || "unthreaded:#{Ecto.UUID.generate()}"

    from = sender(raw_email)
    recipient_evidence = recipient_evidence(from.address, raw_email, parsed_email)

    participants =
      [%{identifier: valid_address(from.address), display_name: from.name, role: :sender}] ++
        visible_participants(raw_email, parsed_email)

    %{
      content: content_with_subject(subject, bodies.text),
      channel_id: valid_address(from.address),
      author_id: valid_address(from.address),
      author_name: from.name,
      thread_id: thread_key,
      message_id: message_id,
      provider: :"email:imap",
      routing_context: %{
        channel_config_id: channel_config_id(config),
        identity_platform: "email",
        conversation_id: thread_key,
        display_subject: subject,
        conversation_type: :recipient_addressed,
        reply_targets: reply_targets(from, raw_email, parsed_email, participants),
        source_scope: mailbox,
        provider_sent_at:
          MessageTimestamp.normalize(
            parsed_header(parsed_email, "date") || get(raw_email, "date", :date),
            :rfc2822
          ),
        audience: %{
          platform: "email",
          sender: recipient_evidence["sender"],
          recipients: recipient_evidence["visible_recipients"],
          participants: participants
        }
      },
      attachments: attachments(raw_email),
      metadata:
        build_metadata(
          mailbox,
          subject,
          headers,
          thread_id,
          thread_key,
          reply_from,
          bodies.html
        )
        |> put_in(["email", "receiving_address"], receiving_address)
        |> put_in(["email", "automatic_reply"], automatic_reply?(parsed_email))
    }
    |> maybe_put_channel_config_id(config)
    |> Incoming.new()
    |> SelfAddresses.filter_incoming(own_addresses)
  rescue
    error -> {:error, {:invalid_email_payload, Exception.message(error)}}
  end

  def to_incoming(_raw_email, _config, _opts), do: {:error, :invalid_email_payload}

  defp maybe_put_channel_config_id(attrs, config) do
    case channel_config_id(config) do
      nil -> attrs
      id -> Map.put(attrs, :channel_config_id, id)
    end
  end

  defp channel_config_id(config) do
    get(config, "id", :id) ||
      case get(config, "config", :config) do
        nested when is_map(nested) -> get(nested, "id", :id)
        _ -> nil
      end
  end

  defp build_metadata(mailbox, subject, headers, thread_id, thread_key, reply_from, html_body) do
    %{
      "subject" => subject,
      "email" => %{
        "mailbox" => mailbox,
        "subject" => subject,
        "reply_from" => reply_from,
        "html_body" => html_body,
        "thread_id" => thread_id,
        "thread_key" => thread_key,
        "headers" => headers
      }
    }
    |> put_thread_anchor(headers)
  end

  # The channel-agnostic anchor the engine reads back opaquely — built once at
  # parse time so no reader needs to interpret email headers.
  defp put_thread_anchor(metadata, headers) do
    case EmailUtils.build_thread_anchor(headers["message_id"], headers["references"]) do
      nil -> metadata
      anchor -> Map.put(metadata, "threading", %{"anchor" => anchor})
    end
  end

  defp sender(raw_email) do
    from = get(raw_email, "from", :from)

    address =
      case from do
        %{address: value} when is_binary(value) -> value
        %{"address" => value} when is_binary(value) -> value
        value when is_binary(value) -> value
        _ -> nil
      end

    name =
      case from do
        %{name: value} when is_binary(value) -> value
        %{"name" => value} when is_binary(value) -> value
        _ -> nil
      end

    %{address: address, name: name}
  end

  # Only From (IMAP envelope) and the visible headers of this message may
  # contribute to its audience. Delivered-To is used for reply routing, not
  # evidence of a hidden recipient; the selected mailbox is just a folder.
  defp recipient_evidence(sender_address, raw_email, parsed_email) do
    %{
      "sender" => valid_address(sender_address),
      "visible_recipients" =>
        [:to, :cc]
        |> Enum.flat_map(fn header ->
          header
          |> visible_addresses(raw_email, parsed_email)
          |> Enum.flat_map(&recipient_addresses/1)
        end)
        |> Enum.uniq()
    }
  end

  defp visible_addresses(header, _raw_email, {:ok, message}) do
    parsed =
      case header do
        :to -> Mail.get_to(message)
        :cc -> Mail.get_cc(message)
      end

    List.wrap(parsed)
  end

  defp visible_addresses(header, raw_email, :error) do
    List.wrap(get(raw_email, Atom.to_string(header), header))
  end

  defp visible_participants(raw_email, parsed_email) do
    Enum.flat_map([:to, :cc], fn role ->
      visible_addresses(role, raw_email, parsed_email)
      |> Enum.flat_map(&named_addresses/1)
      |> Enum.map(&Map.put(&1, :role, role))
    end)
  end

  defp named_addresses({name, address}) do
    case valid_address(address) do
      nil -> []
      id -> [%{identifier: id, display_name: name}]
    end
  end

  defp named_addresses(%{email: address} = value),
    do: named_addresses({Map.get(value, :name), address})

  defp named_addresses(%{"email" => address} = value),
    do: named_addresses({Map.get(value, "name"), address})

  defp named_addresses(value) when is_binary(value) do
    value
    |> RFC2822.parse_recipient_value()
    |> Enum.flat_map(fn
      {_, _} = pair -> named_addresses(pair)
      address -> named_addresses({nil, address})
    end)
  end

  defp named_addresses(_), do: []

  defp reply_targets(from, raw_email, parsed_email, participants) do
    reply_to =
      case parsed_email do
        {:ok, message} -> Mail.Message.get_header(message, "reply-to")
        :error -> get(raw_email, "reply_to", :reply_to)
      end

    primary = List.wrap(reply_to) |> Enum.flat_map(&recipient_addresses/1)
    primary = if primary == [], do: List.wrap(valid_address(from.address)), else: primary

    to =
      (primary ++ for(p <- participants, p.role == :to, do: p.identifier))
      |> Enum.uniq()

    cc =
      for(p <- participants, p.role == :cc, do: p.identifier)
      |> Enum.uniq()
      |> Kernel.--(to)

    %{to: to, cc: cc}
  end

  defp configured_address(config) do
    config = get(config, "config", :config) || config
    settings = get(config, "settings", :settings) || %{}
    imap = get(settings, "imap", :imap) || %{}
    valid_address(get(imap, "username", :username) || get(config, "username", :username))
  end

  # Mail's header map collapses repeated headers. Keep only the first delivery
  # hop, before that collapse; an older forwarding hop may name a real recipient.
  defp receiving_address(raw_email) do
    case first_delivery_header(parsed_email_source(raw_email)) do
      nil ->
        nil

      value ->
        case recipient_addresses(value) do
          [address] -> address
          _ -> nil
        end
    end
  end

  defp first_delivery_header(raw) when is_binary(raw) do
    headers = raw |> String.split(~r/\r?\n\r?\n/, parts: 2) |> hd()

    case Regex.run(~r/^delivered-to:[ \t]*([^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)*)/im, headers) do
      [_, value] -> String.replace(value, ~r/\r?\n[ \t]+/, " ")
      _ -> nil
    end
  end

  defp first_delivery_header(_), do: nil

  defp automatic_reply?(parsed_email) do
    value = parsed_header(parsed_email, "auto-submitted") || ""

    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
    |> Kernel.==("auto-replied")
  end

  defp recipient_addresses({_, address}) when is_binary(address),
    do: List.wrap(valid_address(address))

  defp recipient_addresses(%{email: address}), do: List.wrap(valid_address(address))
  defp recipient_addresses(%{"email" => address}), do: List.wrap(valid_address(address))

  defp recipient_addresses(addresses) when is_binary(addresses) do
    addresses
    |> RFC2822.parse_recipient_value()
    |> Enum.map(fn
      {_, address} -> valid_address(address)
      address -> valid_address(address)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp recipient_addresses(_), do: []

  defp valid_address(address) when is_binary(address) do
    address = address |> String.trim() |> String.downcase()

    if Regex.match?(~r/\A[^\s@<>,]+@[^\s@<>,]+\.[^\s@<>,]+\z/u, address),
      do: address,
      else: nil
  end

  defp valid_address(_), do: nil

  defp extract_bodies(raw_email, parsed_email) do
    text = maybe_string(get(raw_email, "body_text", :body_text))
    html = maybe_string(get(raw_email, "body_html", :body_html))

    case parsed_email do
      {:ok, message} ->
        %{
          text: part_body(Mail.get_text(message)) || text || "",
          html: part_body(Mail.get_html(message)) || html
        }

      :error ->
        %{text: text || "", html: html}
    end
  end

  defp extract_headers(raw_email, parsed_email) do
    %{
      "message_id" =>
        parsed_header(parsed_email, "message-id") || get(raw_email, "message_id", :message_id),
      "in_reply_to" =>
        parsed_header(parsed_email, "in-reply-to") || get(raw_email, "in_reply_to", :in_reply_to),
      "references" =>
        normalize_references(parsed_header(parsed_email, "references")) ||
          normalize_references(get(raw_email, "references", :references))
    }
  end

  defp extract_subject(raw_email, parsed_email) do
    parsed_header(parsed_email, "subject") || get(raw_email, "subject", :subject)
  end

  defp content_with_subject(subject, body) when is_binary(subject) do
    case String.trim(subject) do
      "" -> body
      trimmed_subject -> join_subject_and_body(trimmed_subject, body)
    end
  end

  defp content_with_subject(_subject, body), do: body

  defp join_subject_and_body(subject, ""), do: "Subject: #{subject}"
  defp join_subject_and_body(subject, body), do: "Subject: #{subject}\n\n#{body}"

  defp parsed_header({:ok, message}, key) when is_binary(key) do
    case Mail.Message.get_header(message, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp parsed_header(:error, _key), do: nil

  defp parse_email(nil), do: :error

  defp parse_email(raw_email) when is_binary(raw_email) do
    {:ok, Mail.parse(normalize_line_endings(raw_email))}
  rescue
    _ -> :error
  end

  defp parsed_email_source(raw_email) do
    maybe_string(get(raw_email, "raw_rfc822", :raw_rfc822)) ||
      raw_header_source(get(raw_email, "raw_header", :raw_header))
  end

  defp raw_header_source(header) when is_binary(header) and header != "" do
    header <> "\r\n\r\n"
  end

  defp raw_header_source(_header), do: nil

  defp normalize_line_endings(raw_email) do
    if String.contains?(raw_email, "\r\n") do
      raw_email
    else
      String.replace(raw_email, "\n", "\r\n")
    end
  end

  defp part_body(%{body: value}) when is_binary(value) and value != "", do: value
  defp part_body(_), do: nil

  defp maybe_string(value) when is_binary(value) and value != "", do: value
  defp maybe_string(_), do: nil

  defp normalize_references(nil), do: nil

  defp normalize_references(value) when is_binary(value) do
    value
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_references(_), do: nil

  defp attachments(raw_email) do
    raw_email
    |> get("attachments", :attachments)
    |> List.wrap()
    |> Enum.filter(&match?(%Record{}, &1))
  end

  defp get(map, string_key, atom_key) when is_map(map) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end
end
