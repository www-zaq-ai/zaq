defmodule Zaq.Channels.EmailBridge.ImapAdapter.Parser do
  @moduledoc false

  alias Zaq.Channels.EmailBridge.ImapAdapter.Threading
  alias Zaq.Engine.Messages.Incoming

  @spec to_incoming(map(), map(), keyword()) :: Incoming.t() | {:error, term()}
  def to_incoming(raw_email, config, opts \\ [])

  def to_incoming(raw_email, _config, opts) when is_map(raw_email) and is_list(opts) do
    mailbox = Keyword.get(opts, :mailbox)
    text_body = body_text(raw_email)

    headers = %{
      "message_id" => get(raw_email, "message_id", :message_id),
      "in_reply_to" => get(raw_email, "in_reply_to", :in_reply_to),
      "references" => get(raw_email, "references", :references)
    }

    message_id = headers["message_id"]
    thread_id = Threading.resolve_thread_id(headers)

    from = sender(raw_email)

    %Incoming{
      content: text_body,
      channel_id: mailbox || "INBOX",
      author_id: from.address,
      author_name: from.name,
      thread_id: thread_id,
      message_id: message_id,
      provider: :email,
      metadata: build_metadata(raw_email, mailbox, thread_id)
    }
  rescue
    error -> {:error, {:invalid_email_payload, Exception.message(error)}}
  end

  def to_incoming(_raw_email, _config, _opts), do: {:error, :invalid_email_payload}

  defp build_metadata(raw_email, mailbox, thread_id) do
    %{
      "email" => %{
        "mailbox" => mailbox,
        "subject" => get(raw_email, "subject", :subject),
        "html_body" => get(raw_email, "body_html", :body_html),
        "thread_id" => thread_id,
        "headers" => %{
          "message_id" => get(raw_email, "message_id", :message_id),
          "in_reply_to" => get(raw_email, "in_reply_to", :in_reply_to),
          "references" => get(raw_email, "references", :references)
        },
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

  defp body_text(raw_email) do
    case get(raw_email, "body_text", :body_text) do
      value when is_binary(value) and value != "" -> value
      _ -> ""
    end
  end

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
