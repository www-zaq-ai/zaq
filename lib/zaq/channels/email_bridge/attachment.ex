defmodule Zaq.Channels.EmailBridge.Attachment do
  @moduledoc false

  alias Zaq.Channels.Materializers.CommunicationMedia
  alias Zaq.Contracts.Record

  @provider "email:imap"

  @spec to_record(map(), map()) :: Record.t() | nil
  def to_record(descriptor, context) when is_map(descriptor) and is_map(context) do
    with {:ok, reference} <- reference(descriptor, context),
         {:ok, attrs} <- handle_attrs(descriptor, context),
         {:ok, handle} <- CommunicationMedia.issue(@provider, reference, attrs) do
      %Record{
        id: reference,
        kind: :file,
        name: string(descriptor, :filename),
        mime_type: string(descriptor, :content_type) || "application/octet-stream",
        size: int(descriptor, :encoded_size),
        attributes: record_attributes(descriptor, context, reference),
        materialization_handle: handle
      }
    else
      _ -> nil
    end
  end

  def to_record(_descriptor, _context), do: nil

  @spec to_records([map()], map()) :: [Record.t()]
  def to_records(descriptors, context) when is_list(descriptors) do
    descriptors
    |> Enum.map(&to_record(&1, context))
    |> Enum.filter(&match?(%Record{}, &1))
  end

  def to_records(_descriptors, _context), do: []

  defp reference(descriptor, context) do
    with config_id when not is_nil(config_id) <- context_value(context, :channel_config_id),
         uid_validity when is_integer(uid_validity) and uid_validity > 0 <-
           context_value(context, :uid_validity),
         uid when is_integer(uid) and uid > 0 <- context_value(context, :uid),
         section when is_binary(section) and section != "" <- string(descriptor, :section) do
      {:ok, "email:#{config_id}:#{uid_validity}:#{uid}:#{section}"}
    else
      _ -> {:error, :invalid_email_attachment_context}
    end
  end

  defp handle_attrs(descriptor, context) do
    attrs = %{
      "channel_config_id" => to_string(context_value(context, :channel_config_id)),
      "mailbox" => context_value(context, :mailbox),
      "uid_validity" => context_value(context, :uid_validity),
      "uid" => context_value(context, :uid),
      "section" => string(descriptor, :section),
      "name" => string(descriptor, :filename),
      "mime_type" => string(descriptor, :content_type),
      "media_kind" => "file",
      "size" => int(descriptor, :encoded_size),
      "encoding" => string(descriptor, :encoding),
      "disposition" => string(descriptor, :disposition),
      "content_id" => string(descriptor, :content_id),
      "source_author_id" => context_value(context, :source_author_id),
      "source_channel_id" => context_value(context, :mailbox),
      "source_message_id" => context_value(context, :uid)
    }

    {:ok, drop_blank_values(attrs)}
  end

  defp record_attributes(descriptor, context, reference) do
    %{
      "source_type" => "communication_media",
      "source" => "email",
      "provider" => @provider,
      "source_id" => reference,
      "mailbox" => context_value(context, :mailbox),
      "message_uid" => context_value(context, :uid),
      "uid_validity" => context_value(context, :uid_validity),
      "mime_section" => string(descriptor, :section),
      "encoding" => string(descriptor, :encoding),
      "disposition" => string(descriptor, :disposition),
      "content_id" => string(descriptor, :content_id),
      "channel_config_id" => to_string(context_value(context, :channel_config_id))
    }
    |> drop_blank_values()
  end

  defp context_value(context, key),
    do: Map.get(context, key) || Map.get(context, Atom.to_string(key))

  defp string(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  defp int(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      value when is_integer(value) and value >= 0 -> value
      value when is_binary(value) -> parse_non_negative_int(value)
      _ -> nil
    end
  end

  defp parse_non_negative_int(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp drop_blank_values(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  end
end
