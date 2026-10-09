defmodule Zaq.Channels.IncomingNormalization do
  @moduledoc """
  Provider-local normalization of communication facts for the shared chat bridge.

  Implementations interpret transport payloads and emit only normalized facts.
  Facts describe conversations and message identity, not consumer policy.
  Missing or contradictory transport evidence remains unknown.
  """

  @type result :: %{
          conversation_type: :one_to_one | :room,
          source_scope: String.t() | nil,
          provider_sent_at: DateTime.t() | nil
        }

  @callback normalize(map(), map(), term()) ::
              {:ok, result()} | {:error, :unverified_communication_facts}
  @callback source_scope(term()) :: String.t() | nil

  @doc "Returns whether two provider identifiers refer to the same nonempty room."
  def same_room?(value, room) do
    identifier?(value) and identifier?(room) and to_string(value) == to_string(room)
  end

  @doc "Returns whether a value is a usable provider identifier."
  def identifier?(value) when is_binary(value), do: String.trim(value) != ""
  def identifier?(value) when is_integer(value), do: true
  def identifier?(_), do: false
end
