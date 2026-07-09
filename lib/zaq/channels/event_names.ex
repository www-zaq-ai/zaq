defmodule Zaq.Channels.EventNames do
  @moduledoc """
  Channel-domain event naming helpers for workflow-visible NodeRouter events.
  """

  alias Zaq.Engine.Messages.{Incoming, Outgoing}

  @doc "Builds the event name for a received channel message."
  @spec message_received(Incoming.t(), :agent_requested | :workflow_only, keyword()) :: String.t()
  def message_received(%Incoming{} = incoming, routing_outcome, opts \\ [])
      when routing_outcome in [:agent_requested, :workflow_only] and is_list(opts) do
    provider = incoming.provider |> to_string() |> part()
    config_id = Keyword.get(opts, :channel_config_id) || channel_config_id(incoming)

    "channels:message_received.#{routing_outcome}.#{provider}.#{part(config_id)}"
  end

  @doc "Builds the event name for an agent response being delivered through channels."
  @spec agent_response_delivering(Outgoing.t(), term()) :: String.t()
  def agent_response_delivering(%Outgoing{} = outgoing, original_request \\ nil) do
    provider = outgoing.provider |> to_string() |> part()
    config_id = channel_config_id(outgoing, nil) || channel_config_id(original_request)

    "channels:agent_response.delivering.#{provider}.#{part(config_id)}"
  end

  @doc "Extracts a channel config id from supported channel payloads."
  @spec channel_config_id(term(), term()) :: term()
  def channel_config_id(payload, fallback \\ "unknown")

  def channel_config_id(%Incoming{metadata: metadata}, fallback),
    do: channel_config_id(metadata, fallback)

  def channel_config_id(%Outgoing{metadata: metadata}, fallback),
    do: channel_config_id(metadata, fallback)

  def channel_config_id(metadata, fallback) when is_map(metadata) do
    telemetry =
      Map.get(metadata, "telemetry_dimensions") || Map.get(metadata, :telemetry_dimensions) || %{}

    [
      Map.get(telemetry, "channel_config_id"),
      Map.get(telemetry, :channel_config_id),
      Map.get(metadata, "channel_config_id"),
      Map.get(metadata, :channel_config_id)
    ]
    |> Enum.find_value(&present_channel_config_id/1)
    |> Kernel.||(fallback)
  end

  def channel_config_id(_payload, fallback), do: fallback

  @doc "Normalizes a value for safe inclusion in a dotted event name segment."
  @spec part(term()) :: String.t()
  def part(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unknown"
      part -> part
    end
  end

  defp present_channel_config_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "unknown" -> nil
      value -> value
    end
  end

  defp present_channel_config_id(value) when is_integer(value), do: value
  defp present_channel_config_id(_value), do: nil
end
