defmodule Zaq.Channels.Web.Response do
  @moduledoc """
  Versioned semantic response produced by WebBridge before adapter wire encoding.

  Payloads are allowlisted away from private execution and credential fields.
  Adapters map the semantic type through a trusted `Delivery` descriptor.
  """

  alias Zaq.Channels.Web.Validation

  @types [
    :widget_initialized,
    :conversation_initialized,
    :conversation_created,
    :conversation_history,
    :typing,
    :message_create,
    :message_edit,
    :message_step,
    :message_complete,
    :message_failed,
    :status,
    :error
  ]

  @private_payload_keys [
    :actor,
    :credentials,
    :execution_record,
    :finalization_token,
    :private_trace,
    :token
  ]

  @allowed_fields [
    :protocol_version,
    :request_id,
    :type,
    :conversation_id,
    :message_id,
    :payload
  ]

  @enforce_keys [:protocol_version, :request_id, :type, :payload]
  defstruct @enforce_keys ++ [:conversation_id, :message_id]

  @type response_type ::
          :widget_initialized
          | :conversation_initialized
          | :conversation_created
          | :conversation_history
          | :typing
          | :message_create
          | :message_edit
          | :message_step
          | :message_complete
          | :message_failed
          | :status
          | :error

  @type t :: %__MODULE__{
          protocol_version: 1,
          request_id: String.t(),
          type: response_type(),
          conversation_id: String.t() | nil,
          message_id: String.t() | nil,
          payload: map()
        }

  @doc "Builds a sanitized semantic response for adapter encoding."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Validation.reject_unknown_fields(attrs, @allowed_fields),
         {:ok, protocol_version} <- protocol_version(Validation.fetch(attrs, :protocol_version)),
         {:ok, request_id} <-
           Validation.identifier(Validation.fetch(attrs, :request_id), :request_id,
             required: true
           ),
         {:ok, type} <- type(Validation.fetch(attrs, :type)),
         {:ok, conversation_id} <-
           Validation.identifier(Validation.fetch(attrs, :conversation_id), :conversation_id),
         {:ok, message_id} <-
           Validation.identifier(Validation.fetch(attrs, :message_id), :message_id),
         {:ok, payload} <- Validation.map(Validation.fetch(attrs, :payload), :payload),
         :ok <- Validation.forbidden_keys(payload, @private_payload_keys, :forbidden_payload) do
      {:ok,
       %__MODULE__{
         protocol_version: protocol_version,
         request_id: request_id,
         type: type,
         conversation_id: conversation_id,
         message_id: message_id,
         payload: payload
       }}
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :response}}

  defp protocol_version(nil), do: {:ok, 1}
  defp protocol_version(1), do: {:ok, 1}
  defp protocol_version(_version), do: {:error, {:invalid_field, :protocol_version}}

  defp type(type) when type in @types, do: {:ok, type}
  defp type(_type), do: {:error, {:invalid_field, :type}}
end
