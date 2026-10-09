defmodule Zaq.Engine.Messages.SourceIdentity do
  @moduledoc """
  Stable storage encoding for a Channels-normalized message namespace.

  Channels determines the scope of external message IDs. Engine capture,
  admission and locks use this encoding unchanged, including the historical
  `nil` namespace for connector-global IDs. No provider rules belong here.
  """

  @doc "Encodes the connector and transport-supplied namespace without changing existing keys."
  def account_key(provider, channel_config_id, source_scope),
    do: Jason.encode!([provider, channel_config_id, source_scope])

  @doc "Validates an opaque 1–255-byte namespace; nil is the historical connector-global namespace."
  def valid_scope?(nil), do: true
  def valid_scope?(scope), do: is_binary(scope) and byte_size(scope) in 1..255
end
