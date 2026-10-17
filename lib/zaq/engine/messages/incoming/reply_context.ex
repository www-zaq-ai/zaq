defmodule Zaq.Engine.Messages.Incoming.ReplyContext do
  @moduledoc """
  Normalizes shallow, untrusted quoted-message data within the enclosing ingress scope.

  A reference never authorizes a history lookup. Missing text stays missing; quoted
  media and nested messages are not materialized. Explicit conflicting scope is rejected.
  """

  alias Zaq.Engine.Messages.ConversationIdentity

  @doc "Returns a bounded JSON-safe quote, or nil for absent or conflicting context."
  @spec normalize(term(), map(), term()) :: map() | nil
  def normalize(context, incoming, reference) do
    context = if is_map(context), do: context, else: %{}
    reference = normalize_reference(reference)
    quoted_id = context |> value(:external_message_id) |> normalize_reference()

    scope = %{
      "provider" => to_string(incoming.provider),
      "channel_id" => incoming.channel_id,
      "channel_config_id" => incoming.routing_context.channel_config_id,
      "source_scope" => incoming.routing_context.source_scope
    }

    if matching_scope?(context, scope) and matching_reference?(reference, quoted_id) do
      build(context, scope, reference || quoted_id)
    end
  end

  @doc "Normalizes a quote reference without truncating or accepting invalid UTF-8 identifiers."
  @spec normalize_reference(term()) :: String.t() | nil
  def normalize_reference(value) do
    case ConversationIdentity.normalize(value) do
      value when is_binary(value) and byte_size(value) <= 1_024 ->
        if String.valid?(value), do: value

      _ ->
        nil
    end
  end

  defp build(context, scope, reference) do
    author = value(context, :author)
    author = if is_map(author), do: author, else: %{}
    text = text(value(context, :text), 8_000)

    if reference || text do
      Map.merge(scope, %{
        "external_message_id" => reference,
        "text" => text,
        "author_id" => text(value(context, :author_id) || value(author, :user_id), 255),
        "author_name" =>
          text(
            value(context, :author_name) || value(author, :full_name) || value(author, :user_name),
            255
          )
      })
    end
  end

  defp matching_scope?(context, scope) do
    Enum.all?(scope, fn {key, expected} ->
      supplied = Map.get(context, key, Map.get(context, String.to_existing_atom(key)))
      is_nil(supplied) or supplied == expected
    end)
  end

  defp matching_reference?(nil, _), do: true
  defp matching_reference?(_, nil), do: true
  defp matching_reference?(reference, quoted_id), do: reference == quoted_id

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp text(value, limit) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "", do: String.slice(value, 0, limit)
  end

  defp text(_, _), do: nil
end
