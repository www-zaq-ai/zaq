defmodule Zaq.Engine.Messages.Incoming.RoutingContext do
  @moduledoc """
  Normalized routing facts for an incoming communication message.

  This struct carries only serializable identifiers and attributes derived from
  the transport/configuration layer. Persisted routing policy belongs to
  `Zaq.Engine.IncomingMessageRoutingRule`, not this context.

  `conversation_type` describes one-to-one, room-based, or recipient-addressed
  communication. It does not select a history strategy or confer access. Message
  audience is message-local evidence, never a complete room-membership snapshot.
  Missing or contradictory provider facts remain unknown (`nil`). Consumers own
  interpretation; history kind and title presentation are not transport fields.

  `sender_membership` is message-local presence evidence normalized by Channels.
  It is not a complete membership snapshot or an authentication credential;
  Engine accepts it only after trusted ingress and scoped identity validation.
  """

  alias Zaq.Engine.Messages.Incoming.Audience
  alias Zaq.Engine.Messages.ReplyTargets
  alias Zaq.Engine.Messages.SourceIdentity

  defstruct [
    :channel_config_id,
    :retrieval_channel_id,
    :topic_id,
    :conversation_type,
    :source_scope,
    :audience,
    :identity_platform,
    :sender_membership,
    :provider_sent_at,
    :conversation_id,
    :reply_targets,
    :display_subject,
    attributes: %{}
  ]

  @type t :: %__MODULE__{
          channel_config_id: integer() | nil,
          retrieval_channel_id: integer() | nil,
          topic_id: String.t() | nil,
          conversation_type: :one_to_one | :room | :recipient_addressed | nil,
          source_scope: String.t() | nil | :invalid,
          audience: Audience.t() | nil,
          identity_platform: String.t() | nil,
          sender_membership: map() | nil,
          provider_sent_at: DateTime.t() | nil,
          conversation_id: String.t() | nil,
          reply_targets: ReplyTargets.t() | nil,
          display_subject: String.t() | nil,
          attributes: map()
        }

  @doc "Normalizes arbitrary constructor input into a routing context."
  @spec normalize(term()) :: t()
  def normalize(%__MODULE__{} = context) do
    %__MODULE__{
      channel_config_id: normalize_id(context.channel_config_id),
      retrieval_channel_id: normalize_id(context.retrieval_channel_id),
      topic_id: normalize_topic_id(context.topic_id),
      conversation_type: normalize_conversation_type(context.conversation_type),
      source_scope: normalize_source_scope(context.source_scope),
      audience: Audience.normalize(context.audience),
      identity_platform: normalize_topic_id(context.identity_platform),
      sender_membership: normalize_sender_membership(context.sender_membership),
      provider_sent_at: normalize_timestamp(context.provider_sent_at),
      conversation_id: normalize_topic_id(context.conversation_id),
      reply_targets: ReplyTargets.normalize(context.reply_targets),
      display_subject: normalize_topic_id(context.display_subject),
      attributes: normalize_attributes(context.attributes)
    }
  end

  def normalize(context) when is_map(context) do
    %__MODULE__{
      channel_config_id: normalize_id(fetch(context, :channel_config_id)),
      retrieval_channel_id: normalize_id(fetch(context, :retrieval_channel_id)),
      topic_id: normalize_topic_id(fetch(context, :topic_id)),
      conversation_type: normalize_conversation_type(fetch(context, :conversation_type)),
      source_scope: normalize_source_scope(fetch(context, :source_scope)),
      audience: Audience.normalize(fetch(context, :audience)),
      identity_platform: normalize_topic_id(fetch(context, :identity_platform)),
      sender_membership: normalize_sender_membership(fetch(context, :sender_membership)),
      provider_sent_at: normalize_timestamp(fetch(context, :provider_sent_at)),
      conversation_id: normalize_topic_id(fetch(context, :conversation_id)),
      reply_targets: ReplyTargets.normalize(fetch(context, :reply_targets)),
      display_subject: normalize_topic_id(fetch(context, :display_subject)),
      attributes: normalize_attributes(fetch(context, :attributes))
    }
  end

  def normalize(_context), do: %__MODULE__{}

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_id(id) when is_integer(id) and id > 0, do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_id(_id), do: nil

  defp normalize_topic_id(topic_id) when is_binary(topic_id) do
    case String.trim(topic_id) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_topic_id(_topic_id), do: nil

  defp normalize_source_scope(scope),
    do: if(SourceIdentity.valid_scope?(scope), do: scope, else: :invalid)

  defp normalize_conversation_type(type) when type in [:one_to_one, :room, :recipient_addressed],
    do: type

  defp normalize_conversation_type(_), do: nil

  defp normalize_attributes(attributes) when is_map(attributes), do: attributes
  defp normalize_attributes(_attributes), do: %{}

  defp normalize_sender_membership(evidence) when is_map(evidence) do
    with platform when is_binary(platform) <-
           normalize_topic_id(fetch(evidence, :identity_platform)),
         member when is_binary(member) <- normalize_topic_id(fetch(evidence, :member_id)) do
      %{identity_platform: platform, member_id: member}
    else
      _ -> nil
    end
  end

  defp normalize_sender_membership(_), do: nil

  defp normalize_timestamp(%DateTime{time_zone: "Etc/UTC"} = timestamp), do: timestamp
  defp normalize_timestamp(_), do: nil
end
