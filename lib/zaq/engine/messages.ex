defmodule Zaq.Engine.Messages do
  @moduledoc """
  Shared helpers for canonical message structs.
  """

  @doc "Returns true for non-empty string or integer message identifiers."
  @spec present_message_id?(term()) :: boolean()
  def present_message_id?(message_id) when is_binary(message_id), do: message_id != ""
  def present_message_id?(message_id) when is_integer(message_id), do: true
  def present_message_id?(_message_id), do: false

  @doc "Resolves canonical request_id from metadata only."
  @spec request_id_from_metadata(term()) :: term() | nil
  def request_id_from_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, :request_id) || Map.get(metadata, "request_id")
  end

  def request_id_from_metadata(_metadata), do: nil

  @doc "Resolves run correlation id from metadata first, then message_id."
  @spec correlation_id(term(), term()) :: term() | nil
  def correlation_id(metadata, message_id) do
    request_key(metadata, message_id)
  end

  @doc "Returns canonical request key from incoming."
  @spec request_key(Zaq.Engine.Messages.Incoming.t()) :: term() | nil
  def request_key(%Zaq.Engine.Messages.Incoming{} = incoming) do
    request_key(incoming.metadata, incoming.message_id)
  end

  @doc "Returns canonical request key from metadata/message_id pair."
  @spec request_key(term(), term()) :: term() | nil
  def request_key(metadata, message_id) do
    case request_id_from_metadata(metadata) do
      request_id when is_binary(request_id) and request_id != "" -> request_id
      request_id when is_integer(request_id) -> request_id
      _ -> message_id
    end
  end

  defguard is_present_message_id(message_id)
           when (is_binary(message_id) and message_id != "") or is_integer(message_id)
end
