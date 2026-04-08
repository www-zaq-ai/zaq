defmodule Zaq.Channels.EmailBridge.ImapAdapter.Parser do
  @moduledoc false

  alias Mail
  alias Zaq.Channels.EmailBridge.ImapAdapter.Threading
  alias Zaq.Engine.Messages.Incoming

  @spec to_incoming(map(), map(), keyword()) :: Incoming.t() | {:error, term()}
  def to_incoming(raw_email, config, opts \\ [])

  def to_incoming(raw_email, _config, opts) when is_map(raw_email) and is_list(opts) do
    mailbox = Keyword.get(opts, :mailbox)
    parsed_email = parse_email(maybe_string(get(raw_email, "raw_rfc822", :raw_rfc822)))
    bodies = extract_bodies(raw_email, parsed_email)
    headers = extract_headers(raw_email, parsed_email)
    subject = extract_subject(raw_email, parsed_email)
    reply_from = extract_reply_from(raw_email, parsed_email)

    message_id = headers["message_id"]
    thread_id = Threading.resolve_thread_id(headers)
    thread_key = Threading.resolve_thread_key(headers)

    from = sender(raw_email)

    %Incoming{
      content: bodies.text,
      channel_id: from.address,
      author_id: from.address,
      author_name: from.name,
      thread_id: thread_key,
      message_id: message_id,
      provider: :"email:imap",
      metadata:
        build_metadata(
          raw_email,
          mailbox,
          subject,
          headers,
          thread_id,
          thread_key,
          reply_from,
          bodies.html
        )
    }
  rescue
    error -> {:error, {:invalid_email_payload, Exception.message(error)}}
  end

  def to_incoming(_raw_email, _config, _opts), do: {:error, :invalid_email_payload}

  defp build_metadata(
         raw_email,
         mailbox,
         subject,
         headers,
         thread_id,
         thread_key,
         reply_from,
         html_body
       ) do
    %{
      "subject" => subject,
      "email" => %{
        "mailbox" => mailbox,
        "subject" => subject,
        "reply_from" => reply_from,
        "html_body" => html_body,
        "thread_id" => thread_id,
        "thread_key" => thread_key,
        "threading" => %{
          "message_id" => headers["message_id"],
          "in_reply_to" => headers["in_reply_to"],
          "references" => headers["references"]
        },
        "headers" => headers,
        "attachments" => attachment_refs(raw_email)
      }
    }
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

  defp extract_reply_from(raw_email, parsed_email) do
    parsed_header(parsed_email, "delivered-to")
    |> normalize_email()
    |> case do
      nil ->
        parsed_to_address(parsed_email) || to_address(raw_email)

      email ->
        email
    end
  end

  defp parsed_to_address({:ok, message}) do
    message
    |> Mail.get_to()
    |> List.wrap()
    |> Enum.find_value(&recipient_email/1)
  end

  defp parsed_to_address(:error), do: nil

  defp to_address(raw_email) do
    raw_email
    |> get("to", :to)
    |> recipient_email()
  end

  defp recipient_email({_, email}) when is_binary(email), do: normalize_email(email)
  defp recipient_email(%{email: email}) when is_binary(email), do: normalize_email(email)
  defp recipient_email(%{"email" => email}) when is_binary(email), do: normalize_email(email)

  defp recipient_email(value) when is_list(value) do
    Enum.find_value(value, &recipient_email/1)
  end

  defp recipient_email(value) when is_binary(value), do: normalize_email(value)
  defp recipient_email(_), do: nil

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

  defp normalize_email(nil), do: nil

  defp normalize_email(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      <<_::binary>> = text ->
        case Regex.run(~r/<([^>]+)>/, text, capture: :all_but_first) do
          [email] -> String.trim(email)
          _ -> text
        end

      _ ->
        nil
    end
    |> case do
      "" -> nil
      email -> email
    end
  end

  defp normalize_email(_), do: nil

  defp attachment_refs(raw_email) do
    raw_email
    |> get("attachments", :attachments)
    |> List.wrap()
    |> Enum.map(fn attachment ->
      %{
        "filename" => get(attachment, "filename", :filename),
        "content_type" => get(attachment, "content_type", :content_type),
        "size" => get(attachment, "size", :size),
        "download_ref" => get(attachment, "download_ref", :download_ref)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end)
  end

  defp get(map, string_key, atom_key) when is_map(map) do
    Map.get(map, string_key) || Map.get(map, atom_key)
  end
end
