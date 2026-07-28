defmodule Zaq.Engine.Messages.Incoming.RoutingContext do
  @moduledoc """
  Normalized routing facts for an incoming communication message.

  This struct carries only serializable identifiers and attributes derived from
  the transport/configuration layer. Persisted routing policy belongs to
  `Zaq.Engine.IncomingMessageRoutingRule`, not this context.
  """

  defstruct [
    :channel_config_id,
    :retrieval_channel_id,
    :topic_id,
    attributes: %{}
  ]

  @type t :: %__MODULE__{
          channel_config_id: integer() | nil,
          retrieval_channel_id: integer() | nil,
          topic_id: String.t() | nil,
          attributes: map()
        }

  @doc "Normalizes arbitrary constructor input into a routing context."
  @spec normalize(term()) :: t()
  def normalize(%__MODULE__{} = context) do
    %__MODULE__{
      channel_config_id: normalize_id(context.channel_config_id),
      retrieval_channel_id: normalize_id(context.retrieval_channel_id),
      topic_id: normalize_topic_id(context.topic_id),
      attributes: normalize_attributes(context.attributes)
    }
  end

  def normalize(context) when is_map(context) do
    %__MODULE__{
      channel_config_id: normalize_id(fetch(context, :channel_config_id)),
      retrieval_channel_id: normalize_id(fetch(context, :retrieval_channel_id)),
      topic_id: normalize_topic_id(fetch(context, :topic_id)),
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

  defp normalize_attributes(attributes) when is_map(attributes), do: attributes
  defp normalize_attributes(_attributes), do: %{}
end
