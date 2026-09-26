defmodule Zaq.Engine.Messages.ConversationIdentity do
  @moduledoc """
  Normalizes the transport-neutral conversation identity stamped on an incoming message.

  Channels owns deriving the identity. Engine and Agent use these helpers only to
  consume its JSON-safe identifier values consistently.
  """

  @doc "Returns a trimmed string identifier, converting integers and rejecting blanks."
  @spec identifier(map(), String.t()) :: String.t() | nil
  def identifier(identity, key) when is_map(identity) and is_binary(key) do
    identity
    |> Map.get(key)
    |> normalize()
  end

  @doc "Normalizes one transport identifier value."
  @spec normalize(term()) :: String.t() | nil
  def normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize(value) when is_integer(value), do: Integer.to_string(value)
  def normalize(_value), do: nil

  @doc "Returns the positive integer channel configuration id, when present."
  @spec channel_config_id(map()) :: pos_integer() | nil
  def channel_config_id(identity) when is_map(identity) do
    case Map.get(identity, "channel_config_id") do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  def channel_config_id(_identity), do: nil
end
