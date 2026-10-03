defmodule Zaq.Engine.Messages.Incoming.RoutingContext do
  @moduledoc """
  Normalized routing facts for an incoming communication message.

  This struct carries only serializable identifiers and attributes derived from
  the transport/configuration layer. Persisted routing policy belongs to
  `Zaq.Engine.IncomingMessageRoutingRule`, not this context.
  """

  alias Zaq.Engine.Messages.Incoming.Audience
  alias Zaq.Engine.Messages.ReplyTargets
  alias Zaq.Engine.Messages.SourceIdentity

  defstruct [
    :channel_config_id,
    :retrieval_channel_id,
    :topic_id,
    :history_kind,
    :source_scope,
    :audience,
    :identity_platform,
    :provider_sent_at,
    :conversation_id,
    :reply_targets,
    :display_subject,
    :title_style,
    attributes: %{}
  ]

  @type t :: %__MODULE__{
          channel_config_id: integer() | nil,
          retrieval_channel_id: integer() | nil,
          topic_id: String.t() | nil,
          history_kind: :direct | :channel | :replicated | nil,
          source_scope: String.t() | nil | :invalid,
          audience: Audience.t() | nil,
          identity_platform: String.t() | nil,
          provider_sent_at: DateTime.t() | nil,
          conversation_id: String.t() | nil,
          reply_targets: ReplyTargets.t() | nil,
          display_subject: String.t() | nil,
          title_style: :person | :person_subject | nil,
          attributes: map()
        }

  @doc "Normalizes arbitrary constructor input into a routing context."
  @spec normalize(term()) :: t()
  def normalize(%__MODULE__{} = context) do
    %__MODULE__{
      channel_config_id: normalize_id(context.channel_config_id),
      retrieval_channel_id: normalize_id(context.retrieval_channel_id),
      topic_id: normalize_topic_id(context.topic_id),
      history_kind: normalize_history_kind(context.history_kind),
      source_scope: normalize_source_scope(context.source_scope),
      audience: Audience.normalize(context.audience),
      identity_platform: normalize_topic_id(context.identity_platform),
      provider_sent_at: normalize_timestamp(context.provider_sent_at),
      conversation_id: normalize_topic_id(context.conversation_id),
      reply_targets: ReplyTargets.normalize(context.reply_targets),
      display_subject: normalize_topic_id(context.display_subject),
      title_style: normalize_title_style(context.title_style),
      attributes: normalize_attributes(context.attributes)
    }
  end

  def normalize(context) when is_map(context) do
    %__MODULE__{
      channel_config_id: normalize_id(fetch(context, :channel_config_id)),
      retrieval_channel_id: normalize_id(fetch(context, :retrieval_channel_id)),
      topic_id: normalize_topic_id(fetch(context, :topic_id)),
      history_kind: normalize_history_kind(fetch(context, :history_kind)),
      source_scope: normalize_source_scope(fetch(context, :source_scope)),
      audience: Audience.normalize(fetch(context, :audience)),
      identity_platform: normalize_topic_id(fetch(context, :identity_platform)),
      provider_sent_at: normalize_timestamp(fetch(context, :provider_sent_at)),
      conversation_id: normalize_topic_id(fetch(context, :conversation_id)),
      reply_targets: ReplyTargets.normalize(fetch(context, :reply_targets)),
      display_subject: normalize_topic_id(fetch(context, :display_subject)),
      title_style: normalize_title_style(fetch(context, :title_style)),
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

  defp normalize_history_kind(kind) when kind in [:direct, :channel, :replicated], do: kind
  defp normalize_history_kind(_kind), do: nil

  defp normalize_attributes(attributes) when is_map(attributes), do: attributes
  defp normalize_attributes(_attributes), do: %{}

  defp normalize_timestamp(%DateTime{time_zone: "Etc/UTC"} = timestamp), do: timestamp
  defp normalize_timestamp(_), do: nil

  defp normalize_title_style(style) when style in [:person, :person_subject], do: style
  defp normalize_title_style(_), do: nil
end
